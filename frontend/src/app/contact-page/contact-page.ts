import { Component, signal } from '@angular/core';

interface TeamMember {
  name: string;
  /** A short, general description of the person (not their role in the project). */
  description: string;
  /** Path to the photo in public/, e.g. '/team/maria.jpg'. Leave empty to show initials. */
  photo?: string;
  email?: string;
  phone?: string;
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
  // Αν λείπει email ή phone, η αντίστοιχη γραμμή δεν εμφανίζεται.
  // ============================================================
  readonly members: TeamMember[] = [
    {
      name: 'Konstantinos Goutsias',
      description:
        'Electrical and Computer Engineering graduate of the Technical University of Crete, with a specialization in Machine Learning and Artificial Intelligence.',
      photo: '/team/kostas.png',
      email: 'gkostassg@gmail.com',
      phone: '+30 694 831 1000',
    },
    {
      name: 'Anna Allagioti',
      description:
        'Electrical and Computer Engineer, currently an MSc student in Data Science and Information Technologies with a specialization in Artificial Intelligence.',
      photo: '/team/anna.png',
      email: 'annaallayioti@gmail.com',
      phone: '+30 694 789 8342',
    },
    {
      name: 'Grigoris Triantafyllou',
      description:
        'Informatics graduate of the Athens University of Economics and Business (AUEB).',
      photo: '/team/greg.png',
      email: 'gregorestriantafyllou@gmail.com',
      phone: '+30 698 836 1234',
    },
    {
      name: 'Solonas',
      description:
        'Comes from the School of Electrical and Computer Engineering at the National Technical University of Athens (NTUA).',
      photo: '/team/solonas.png',
      email: 'solonasdamigos@gmail.com',
      phone: '+30 694 628 0070',
    },
    {
      name: 'Dimitrios Skylakos',
      description:'unemployed',
      photo: '/team/dimitis.jpg',
      email: 'dimskylakos@gmail.com',
      phone: '+30 694 052 9218',
    }
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