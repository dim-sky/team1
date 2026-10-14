import { Component, inject, input } from '@angular/core';
import { RouterLink, RouterLinkActive } from '@angular/router';
import { MsalService } from '@azure/msal-angular';

@Component({
  selector: 'app-navbar',
  standalone: true,
  imports: [RouterLink, RouterLinkActive],
  templateUrl: './navbar.html',
  styleUrl: './navbar.css',
})
export class Navbar {
  private msal = inject(MsalService);

  userName = input<string | undefined>();

  // Το όνομα που εμφανίζεται δίπλα στο λογότυπο
  brand = 'Skillakia';
  menuOpen = false;

  links = [
    { label: 'Chat', path: '/home' },
    { label: 'Reports', path: '/report' },
    { label: 'Contact us', path: '/contact' },
  ];

  toggleMenu(): void {
    this.menuOpen = !this.menuOpen;
  }

  closeMenu(): void {
    this.menuOpen = false;
  }

    async logout(): Promise<void> {
    this.closeMenu();
    const account = this.msal.instance.getActiveAccount() ?? undefined;
 
    // Σβήνει τη σύνδεση μόνο από την εφαρμογή, χωρίς redirect στη Microsoft
    await this.msal.instance.clearCache({ account });
 
    // Καθαρή επαναφόρτωση: η εφαρμογή ξεκινά ως "αποσυνδεδεμένος"
    window.location.assign('/');
  }
}