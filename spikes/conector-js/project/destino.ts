// POC DESECHABLE: destino Notion escrito como código de un proyecto de recetas.
// El host es dueño de la credencial, el transporte y el checkpoint.
import { Client } from "@notionhq/client";
import { z } from "zod";

type Receipt = { version: 1; pageId: string; url: string };
type Input = {
  action: "inspect" | "publish" | "update" | "remove" | "upload" | "security";
  origin: string;
  parentId?: string;
  receipt?: Receipt;
  title?: string;
  authorizationProbe?: string;
  attachUpload?: boolean;
};
type Context = {
  cuenta: { fetch: typeof fetch };
  checkpoint: (receipt: Receipt) => Promise<void>;
};

const destinationForm = z.object({
  parentId: z.string().min(1).describe("Página de Notion donde publicar"),
  titlePrefix: z.string().default("Escriba"),
  attachText: z.boolean().default(false),
});

function titleProperty(title: string) {
  return { title: [{ text: { content: title } }] };
}

function paragraphs(title: string) {
  return [
    {
      object: "block" as const,
      type: "paragraph" as const,
      paragraph: {
        rich_text: [{ type: "text" as const, text: { content: `Nota sintética: ${title}` } }],
      },
    },
    {
      object: "block" as const,
      type: "paragraph" as const,
      paragraph: {
        rich_text: [{ type: "text" as const, text: { content: "Contenido de prueba sin datos personales." } }],
      },
    },
  ];
}

function silentWav(): Blob {
  const pcmBytes = 160; // 80 fotogramas PCM16 mono.
  const bytes = new ArrayBuffer(44 + pcmBytes);
  const view = new DataView(bytes);
  const word = (offset: number, value: string) => {
    for (let i = 0; i < value.length; i++) view.setUint8(offset + i, value.charCodeAt(i));
  };
  word(0, "RIFF");
  view.setUint32(4, bytes.byteLength - 8, true);
  word(8, "WAVE");
  word(12, "fmt ");
  view.setUint32(16, 16, true);
  view.setUint16(20, 1, true); // PCM.
  view.setUint16(22, 1, true); // Mono.
  view.setUint32(24, 8000, true);
  view.setUint32(28, 16000, true);
  view.setUint16(32, 2, true);
  view.setUint16(34, 16, true);
  word(36, "data");
  view.setUint32(40, pcmBytes, true);
  return new Blob([bytes], { type: "audio/wav" });
}

function requiredReceipt(input: Input): Receipt {
  if (!input.receipt || input.receipt.version !== 1 || !input.receipt.pageId) {
    throw new Error("Se necesita un recibo de publicación versión 1");
  }
  return input.receipt;
}

async function rejected(operation: () => Promise<unknown>) {
  try {
    await operation();
    return { rejected: false };
  } catch (error) {
    return { rejected: true, reason: String(error) };
  }
}

export async function run(input: Input, contexto: Context) {
  if (input.action === "inspect") {
    // La inspección no crea Client ni toca el transporte de la cuenta.
    return {
      checks: { readonly: true, schemaGenerated: true },
      schema: z.toJSONSchema(destinationForm),
    };
  }

  if (input.action === "security") {
    if (!input.authorizationProbe) throw new Error("Falta authorizationProbe");
    const outside = await rejected(() => contexto.cuenta.fetch("http://127.0.0.1:1/probe"));
    const authorization = await rejected(() =>
      contexto.cuenta.fetch(`${input.origin}/v1/users/me`, {
        headers: { Authorization: input.authorizationProbe },
      }),
    );
    const redirect = await rejected(() =>
      contexto.cuenta.fetch(`${input.origin}/poc/redirect`),
    );
    const response = await contexto.cuenta.fetch(`${input.origin}/poc/headers`);
    const body = await response.text();
    const headers = {
      authorizationHidden: response.headers.get("authorization") === null,
      cookieHidden: response.headers.get("set-cookie") === null,
      bodyRedacted: body.includes("[REDACTED]"),
    };
    return { checks: { outside, authorization, redirect, headers } };
  }

  const notion = new Client({
    baseUrl: input.origin,
    fetch: contexto.cuenta.fetch,
    retry: false,
    timeoutMs: 1500,
  });
  const title = input.title ?? "Nota sintética del POC";

  if (input.action === "publish") {
    const page = await notion.pages.create({
      parent: { page_id: input.parentId ?? "parent-page" },
      properties: { title: titleProperty(title) },
    });
    const receipt: Receipt = { version: 1, pageId: page.id, url: page.url };
    // El punto crítico: una página ya creada se recuerda antes de añadir bloques.
    await contexto.checkpoint(receipt);
    const appended = await notion.blocks.children.append({
      block_id: page.id,
      children: paragraphs(title),
    });
    return {
      checks: { checkpointBeforeAppend: true },
      receipt,
      appended: appended.results.length,
    };
  }

  if (input.action === "update") {
    const receipt = requiredReceipt(input);
    await notion.pages.update({
      page_id: receipt.pageId,
      properties: { title: titleProperty(title) },
    });
    let cursor: string | undefined;
    const previousBlockIds: string[] = [];
    do {
      const page = await notion.blocks.children.list({
        block_id: receipt.pageId,
        page_size: 100,
        ...(cursor ? { start_cursor: cursor } : {}),
      });
      previousBlockIds.push(...page.results.map((block) => block.id));
      cursor = page.has_more ? (page.next_cursor ?? undefined) : undefined;
    } while (cursor);
    for (const blockId of previousBlockIds) {
      await notion.blocks.delete({ block_id: blockId });
    }
    const appended = await notion.blocks.children.append({
      block_id: receipt.pageId,
      children: paragraphs(title),
    });
    return {
      checks: { paginated: true },
      receipt,
      listed: previousBlockIds.length,
      removed: previousBlockIds.length,
      appended: appended.results.length,
    };
  }

  if (input.action === "remove") {
    const receipt = requiredReceipt(input);
    const page = await notion.pages.update({ page_id: receipt.pageId, archived: true });
    return { checks: { archived: page.archived === true }, receipt };
  }

  if (input.action === "upload") {
    const file = silentWav();
    const created = await notion.fileUploads.create({
      mode: "single_part",
    });
    const sent = await notion.fileUploads.send({
      file_upload_id: created.id,
      file: { filename: "escriba-poc.wav", data: file },
    });
    if (input.attachUpload) {
      const receipt = requiredReceipt(input);
      await notion.blocks.children.append({
        block_id: receipt.pageId,
        children: [{
          object: "block",
          type: "audio",
          audio: { type: "file_upload", file_upload: { id: created.id } },
        }],
      });
    }
    return {
      checks: { sent: sent.id === created.id, attached: Boolean(input.attachUpload) },
      uploadId: created.id,
      size: file.size,
    };
  }

  throw new Error(`Acción desconocida: ${input.action}`);
}
