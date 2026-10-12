import { Component, signal, OnInit, inject } from '@angular/core';
import { RouterOutlet } from '@angular/router';
import { MsalService } from '@azure/msal-angular';
import { Navbar } from './navbar/navbar';
import { LoginPage } from './login-page/login-page';


@Component({
  selector: 'app-root',
  imports: [RouterOutlet, Navbar, LoginPage],
  templateUrl: './app.html',
  styleUrl: './app.css'
})
export class App implements OnInit {
  protected readonly title = signal('team1_frontend');
  protected readonly name = signal<string | undefined>(undefined);

  private msal = inject(MsalService);

  ngOnInit() {
    // Ολοκληρώνει το login όταν ο χρήστης επιστρέφει από το Entra
    this.msal.handleRedirectObservable().subscribe(result => {
      if (result?.account) this.msal.instance.setActiveAccount(result.account);
      const account = this.msal.instance.getActiveAccount()
        ?? this.msal.instance.getAllAccounts()[0];
      this.name.set(account?.name);
    });
  }

  login() {
    this.msal.loginRedirect({ scopes: ['User.Read'] });
  }

  logout() {
    this.msal.logoutRedirect();
  }
}