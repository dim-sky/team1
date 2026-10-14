import { Component, signal } from '@angular/core';

interface TeamMember {
  name: string;
  role: string;
  description: string;
  /** Path to the photo in public/, e.g. '/team/maria.jpg'. Leave empty to show initials. */
  photo?: string;
  email?: string;
  linkedin?: string;
  github?: string;
}

@Component({
  selector: 'app-contact-page',
  standalone: true,
  templateUrl: './contact-page.html',
  styleUrl: './contact-page.css',
})
export class ContactPage {
  // ============================================================
  // Τα μέλη της ομάδας: συμπλήρωσε τα στοιχεία σας εδώ.
  // Οι φωτογραφίες μπαίνουν στο φάκελο public/team/
  // Αν λείπει μια φωτογραφία, εμφανίζονται τα αρχικά του ονόματος.
  // Αν λείπει email/linkedin/github, το αντίστοιχο κουμπί δεν εμφανίζεται.
  // ============================================================
  readonly members: TeamMember[] = [
    {
      name: 'Member One',
      role: 'Data engineering',
      description:
        'Built the Databricks pipelines that ingest the raw files and turn them into trusted Bronze and Silver tables, including the data-quality checks and quarantine.',
      photo: '/team/member1.jpg',
      email: 'member1@example.com',
      linkedin: 'https://www.linkedin.com/in/member1',
      github: 'https://github.com/member1',
    },
    {
      name: 'Member Two',
      role: 'Analytics',
      description:
        'Designed the Gold star schema and the Fabric semantic model, wrote the DAX measures and built the Power BI report.',
      photo: '/team/member2.jpg',
      email: 'member2@example.com',
      linkedin: 'https://www.linkedin.com/in/member2',
      github: 'https://github.com/member2',
    },
    {
      name: 'Member Three',
      role: 'AI and API',
      description:
        'Built the FastAPI layer and the LangChain assistant, including the data tools the model is allowed to call and how answers are grounded.',
      photo: '/team/member3.jpg',
      email: 'member3@example.com',
      linkedin: 'https://www.linkedin.com/in/member3',
      github: 'https://github.com/member3',
    },
    {
      name: 'Member Four',
      role: 'Cloud and DevOps',
      description:
        'Set up the Azure resources, identity and Key Vault, and the CI/CD pipeline that tests and deploys the solution.',
      photo: '/team/member4.jpg',
      email: 'member4@example.com',
      linkedin: 'https://www.linkedin.com/in/member4',
      github: 'https://github.com/member4',
    },
    {
      name: 'Member Five',
      role: 'Project management',
      description:
        'Planned the milestones, coordinated the work across the team, tracked risks and dependencies, and owned the final delivery.',
      photo: '/team/member5.jpg',
      email: 'member5@example.com',
      linkedin: 'https://www.linkedin.com/in/member5',
      github: 'https://github.com/member5',
    },
  ];

  // Φωτογραφίες που απέτυχαν να φορτώσουν (για να δείξουμε αρχικά)
  private readonly failedPhotos = signal<ReadonlySet<string>>(new Set());

  showPhoto(member: TeamMember): boolean {
    return !!member.photo && !this.failedPhotos().has(member.photo);
  }

  onPhotoError(member: TeamMember): void {
    if (!member.photo) return;
    const photo = member.photo;
    this.failedPhotos.update((set) => new Set(set).add(photo));
  }

  initials(name: string): string {
    return name
      .split(/\s+/)
      .filter(Boolean)
      .slice(0, 2)
      .map((part) => part[0].toUpperCase())
      .join('');
  }
}