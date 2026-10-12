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

  brand = 'Team1';
  menuOpen = false;

  links = [
    { label: 'Chat', path: '/home' },
    { label: 'About', path: '/about' },
    { label: 'Contact us', path: '/contact' },
  ];

  toggleMenu(): void {
    this.menuOpen = !this.menuOpen;
  }

  closeMenu(): void {
    this.menuOpen = false;
  }

  logout(): void {
    this.closeMenu();
    this.msal.logoutRedirect();
  }
}