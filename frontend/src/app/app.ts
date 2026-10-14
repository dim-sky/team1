import { Component, OnDestroy, OnInit, inject, signal } from '@angular/core';
import { RouterOutlet } from '@angular/router';
import { MsalBroadcastService, MsalService } from '@azure/msal-angular';
import { EventMessage, InteractionStatus } from '@azure/msal-browser';
import { Subject, filter, takeUntil } from 'rxjs';
import { Navbar } from './navbar/navbar';
import { LoginPage } from './login-page/login-page';

type AuthState = 'loading' | 'signedIn' | 'signedOut';

@Component({
  selector: 'app-root',
  imports: [RouterOutlet, Navbar, LoginPage],
  templateUrl: './app.html',
  styleUrl: './app.css',
})
export class App implements OnInit, OnDestroy {
  // 'loading' μέχρι το MSAL να τελειώσει την επεξεργασία του redirect.
  // Έτσι δεν εμφανίζεται για λίγο η σελίδα σύνδεσης.
  protected readonly authState = signal<AuthState>('loading');
  protected readonly name = signal<string | undefined>(undefined);

  private msal = inject(MsalService);
  private broadcast = inject(MsalBroadcastService);
  private readonly destroy$ = new Subject<void>();

  ngOnInit(): void {
    // 1. Επεξεργασία της απάντησης από το Entra (όταν επιστρέφει ο χρήστης)
    this.msal
      .handleRedirectObservable()
      .pipe(takeUntil(this.destroy$))
      .subscribe({
        next: (result) => {
          if (result?.account) {
            this.msal.instance.setActiveAccount(result.account);
          }
        },
        error: (err) => {
          // Αν αποτύχει, το βλέπουμε στο console αντί να γυρνάμε σιωπηλά στο login
          console.error('[auth] Handling the redirect from Entra ID failed:', err);
          this.updateAuthState();
        },
      });

    // 2. Αποφασίζουμε τι θα δείξουμε ΜΟΝΟ όταν το MSAL έχει τελειώσει κάθε interaction
    this.broadcast.inProgress$
      .pipe(
        filter((status) => status === InteractionStatus.None),
        takeUntil(this.destroy$),
      )
      .subscribe(() => this.updateAuthState());

    // 3. Καταγραφή αποτυχιών σύνδεσης/token για debugging.
    // Ελέγχουμε το όνομα του event αντί για συγκεκριμένα EventType,
    // γιατί διαφέρουν μεταξύ εκδόσεων του msal-browser.
    this.broadcast.msalSubject$
      .pipe(
        filter((event: EventMessage) => String(event.eventType).toLowerCase().includes('failure')),
        takeUntil(this.destroy$),
      )
      .subscribe((event) => console.error(`[auth] ${event.eventType}:`, event.error));
  }

  ngOnDestroy(): void {
    this.destroy$.next();
    this.destroy$.complete();
  }

  private updateAuthState(): void {
    let account = this.msal.instance.getActiveAccount();

    if (!account) {
      const accounts = this.msal.instance.getAllAccounts();
      if (accounts.length > 0) {
        account = accounts[0];
        this.msal.instance.setActiveAccount(account);
      }
    }

    this.name.set(account?.name ?? account?.username);
    this.authState.set(account ? 'signedIn' : 'signedOut');
  }
}