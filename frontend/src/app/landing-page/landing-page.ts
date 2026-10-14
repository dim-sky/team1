import { Component } from '@angular/core';
import { RouterLink } from '@angular/router';

type AreaIcon = 'incidents' | 'assets' | 'teams' | 'monitoring';

interface DataArea {
  name: string;
  icon: AreaIcon;
  description: string;
  examples: string[];
}

interface PipelineStep {
  name: string;
  description: string;
}

@Component({
  selector: 'app-landing-page',
  standalone: true,
  imports: [RouterLink],
  templateUrl: './landing-page.html',
  styleUrl: './landing-page.css',
})
export class LandingPage {
  // Η ερώτηση που φαίνεται στο παράδειγμα δεξιά από τον τίτλο
  readonly previewQuestion =
    'Which three services took longest to resolve P1 and P2 incidents?';

  // Τι μπορεί να ρωτήσει ο χρήστης, ανά σύνολο δεδομένων
  readonly areas: DataArea[] = [
    {
      name: 'Incidents',
      icon: 'incidents',
      description: 'Volume, severity and how fast incidents are handled.',
      examples: ['Open backlog', 'P1/P2 rate', 'Mean time to acknowledge and resolve', 'SLA compliance'],
    },
    {
      name: 'Assets and services',
      icon: 'assets',
      description: 'Which systems are affected and how often.',
      examples: ['Incidents per business service', 'Critical production assets', 'Recurring problem assets'],
    },
    {
      name: 'Teams',
      icon: 'teams',
      description: 'Who handles the work and how they perform.',
      examples: ['Workload per team', 'Resolution time per team', 'Incidents handled by severity'],
    },
    {
      name: 'Monitoring events',
      icon: 'monitoring',
      description: 'The alerts that came before an incident.',
      examples: ['Alerts preceding incidents', 'Most frequent triggering metrics', 'Alert volume over time'],
    },
  ];

  // Τα στάδια της αρχιτεκτονικής (με τη σειρά που ρέουν τα δεδομένα)
  readonly steps: PipelineStep[] = [
    { name: 'Source files', description: 'Incident, asset and team CSVs, plus monitoring events in JSON.' },
    { name: 'Bronze', description: 'Raw records stored as they arrived, with file and batch lineage.' },
    { name: 'Silver', description: 'Records cleaned, deduplicated and checked. Failures go to quarantine.' },
    { name: 'Gold', description: 'A star schema of incident and monitoring facts with shared dimensions.' },
    { name: 'Fabric and Power BI', description: 'Governed measures and the operational report.' },
    { name: 'API and assistant', description: 'Secured endpoints and an LLM that can only call approved data tools.' },
  ];

  scrollTo(id: string): void {
    document.getElementById(id)?.scrollIntoView({ behavior: 'smooth', block: 'start' });
  }
}