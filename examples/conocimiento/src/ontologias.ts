export const ontologias = [
  {
    id: "ejemplo.reuniones",
    name: "Reuniones y acuerdos",
    version: 1,
    migrations: [
      {
        version: 1,
        sql: `
          DEFINE TABLE reunion SCHEMAFULL PERMISSIONS FULL;
          DEFINE FIELD titulo ON reunion TYPE string;
          DEFINE FIELD fecha ON reunion TYPE datetime;
          DEFINE TABLE acuerdo SCHEMAFULL PERMISSIONS FULL;
          DEFINE FIELD titulo ON acuerdo TYPE string;
          DEFINE FIELD estado ON acuerdo TYPE string;
          DEFINE TABLE surgio_en TYPE RELATION IN acuerdo OUT reunion ENFORCED SCHEMAFULL PERMISSIONS FULL;
        `,
      },
    ],
    collections: [
      {
        table: "reunion",
        label: "Reuniones",
        titleField: "titulo",
        fields: [
          { key: "titulo", label: "Título", type: "text", required: true },
          { key: "fecha", label: "Fecha", type: "date" },
        ],
      },
      {
        table: "acuerdo",
        label: "Acuerdos",
        titleField: "titulo",
        fields: [
          { key: "titulo", label: "Título", type: "text", required: true },
          { key: "estado", label: "Estado", type: "text" },
        ],
      },
      {
        table: "surgio_en",
        label: "Origen del acuerdo",
        titleField: "id",
        fields: [],
        relation: { from: "acuerdo", to: "reunion" },
      },
    ],
  },
] satisfies readonly Ontologia[];
