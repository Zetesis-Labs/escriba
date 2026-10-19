function parsed(candidate: string): { value: unknown } | undefined {
  try {
    return { value: JSON.parse(candidate) };
  } catch {
    return undefined;
  }
}

function fenced(answer: string): string[] {
  return [...answer.matchAll(/```[^\S\n]*[A-Za-z]*\s*([\s\S]*?)```/g)].map((match) => match[1] ?? "");
}

// Scans to the bracket that closes the one at `start`, skipping brackets inside strings.
function balanced(answer: string, start: number): string | undefined {
  const stack: string[] = [];
  let inString = false;
  for (let index = start; index < answer.length; index++) {
    const char = answer[index];
    if (inString) {
      if (char === "\\") index++;
      else if (char === '"') inString = false;
    } else if (char === '"') inString = true;
    else if (char === "{" || char === "[") stack.push(char === "{" ? "}" : "]");
    else if (char === "}" || char === "]") {
      if (stack.pop() !== char) return undefined;
      if (!stack.length) return answer.slice(start, index + 1);
    }
  }
  return undefined;
}

function embedded(answer: string): { value: unknown } | undefined {
  for (let index = 0; index < answer.length; index++) {
    if (answer[index] !== "{" && answer[index] !== "[") continue;
    const candidate = balanced(answer, index);
    const found = candidate === undefined ? undefined : parsed(candidate);
    if (found) return found;
  }
  return undefined;
}

export function answerJson(answer: string): unknown {
  const whole = parsed(answer.trim());
  if (whole) return whole.value;
  for (const block of fenced(answer)) {
    const found = parsed(block.trim()) ?? embedded(block);
    if (found) return found.value;
  }
  return embedded(answer)?.value;
}
