import { Component, inject, signal } from '@angular/core';
import { toSignal } from '@angular/core/rxjs-interop';
import { MsalBroadcastService, MsalService } from '@azure/msal-angular';
import { InteractionStatus } from '@azure/msal-browser';
import { map } from 'rxjs';

@Component({
  selector: 'app-login-page',
  standalone: true,
  templateUrl: './login-page.html',
  styleUrl: './login-page.css',
})
export class LoginPage {
  private msal = inject(MsalService);
  private broadcast = inject(MsalBroadcastService);

  brand = 'Skillakiaaaaaa';
  isRedirecting = signal(false);

  // true μόνο όταν το MSAL δεν κάνει τίποτα άλλο (π.χ. δεν επεξεργάζεται ακόμα την επιστροφή από logout)
  isReady = toSignal(
    this.broadcast.inProgress$.pipe(map((status) => status === InteractionStatus.None)),
    { initialValue: false }
  );

  login(): void {
    if (!this.isReady() || this.isRedirecting()) return;
    this.isRedirecting.set(true);

    this.msal.loginRedirect({
      scopes: ['User.Read'],
      // Μετά από logout, ζητάει επιλογή λογαριασμού αντί να ξανασυνδεθεί αυτόματα
      prompt: 'select_account',
    });
  }
}