// =====================================================================
//  ΡΥΘΜΙΣΕΙΣ POWER BI: ΑΥΤΟ ΕΙΝΑΙ ΤΟ ΜΟΝΟ ΑΡΧΕΙΟ ΠΟΥ ΣΥΜΠΛΗΡΩΝΕΙΣ
// =====================================================================
//
//  Για κάθε αναφορά συμπλήρωσε:
//    id          -> ένα μοναδικό όνομα της επιλογής σου (π.χ. 'sales')
//    title       -> ο τίτλος που θα φαίνεται στη λίστα
//    description -> (προαιρετικό) μια σύντομη περιγραφή
//    embedUrl    -> το URL της αναφοράς από το Power BI Service
//
//  Πού βρίσκω το embedUrl:
//    1. Στο Power BI Desktop: Home -> Publish -> διάλεξε workspace.
//    2. Άνοιξε την αναφορά στο https://app.powerbi.com
//    3. File -> Embed report -> Website or portal
//    4. Αντέγραψε τον ΠΡΩΤΟ σύνδεσμο (αρχίζει με
//       https://app.powerbi.com/reportEmbed?reportId=...)
//       και επικόλλησέ τον στο embedUrl.
//
//  Μπορείς να προσθέσεις ή να αφαιρέσεις όσες αναφορές θέλεις.
// =====================================================================

export interface PowerBiReport {
  id: string;
  title: string;
  description?: string;
  embedUrl: string;
}

export const POWER_BI_REPORTS: PowerBiReport[] = [
  {
    id: 'main-report',
    title: 'Αναφορές',              // <-- άλλαξε τον τίτλο αν θέλεις
    description: 'Πίνακας ελέγχου', // <-- άλλαξε την περιγραφή αν θέλεις
    embedUrl:
      'https://app.powerbi.com/view?r=eyJrIjoiZWY0NWE4YTgtODFkYy00MjUwLTk2MmItY2MwNzdjNmQ2NDZlIiwidCI6IjY1ZmM4NGMyLWJlZGItNDhmNi05OWQyLTZmODMzY2UxMGRjYSJ9',
  },
];