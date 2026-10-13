import { Component, inject, signal } from '@angular/core';
import { MsalService } from '@azure/msal-angular';

@Component({
  selector: 'app-login-page',
  standalone: true,
  templateUrl: './login-page.html',
  styleUrl: './login-page.css',
})
export class LoginPage {
  private msal = inject(MsalService);

  // Ίδιο όνομα με το navbar (το λογότυπο δεν έχει πια όνομα μέσα)
  brand = 'Skillakia';
  isRedirecting = signal(false);

  login(): void {
    if (this.isRedirecting()) return;
    this.isRedirecting.set(true);
    this.msal.loginRedirect({ scopes: ['User.Read'] });
  }
}