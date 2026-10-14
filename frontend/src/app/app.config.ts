import { ApplicationConfig, inject, provideAppInitializer, provideBrowserGlobalErrorListeners } from '@angular/core';
import { provideRouter } from '@angular/router';
import { provideHttpClient, withInterceptorsFromDi, HTTP_INTERCEPTORS } from '@angular/common/http';
import { PublicClientApplication, InteractionType, BrowserCacheLocation, IPublicClientApplication } from '@azure/msal-browser';
import {
  MSAL_INSTANCE, MSAL_GUARD_CONFIG, MSAL_INTERCEPTOR_CONFIG,
  MsalService, MsalGuard, MsalBroadcastService, MsalInterceptor
} from '@azure/msal-angular';

import { baseURL } from './strings/endpoints';

import { routes } from './app.routes';

const TENANT_ID = 'b1732512-60e5-48fb-92e8-8d6902ac1349';
const SPA_CLIENT_ID = '37815f98-bbed-4937-95a3-d0ca7960c989';
const LOGIN_SCOPES = ['User.Read'];
// Όταν φτιάξεις backend: const API_SCOPE = 'api://<api-client-id>/access_as_user';

const msalInstance = new PublicClientApplication({
  auth: {
    clientId: SPA_CLIENT_ID,
    authority: `https://login.microsoftonline.com/${TENANT_ID}`,
    // Πρέπει να είναι καταχωρημένο ΑΚΡΙΒΩΣ έτσι στο Entra, κάτω από "Single-page application"
    redirectUri: window.location.origin,
    postLogoutRedirectUri: window.location.origin,
  },
  cache: { cacheLocation: BrowserCacheLocation.LocalStorage },
});

export const appConfig: ApplicationConfig = {
  providers: [
    provideBrowserGlobalErrorListeners(),
    provideRouter(routes),

    // HTTP + interceptor που προσθέτει αυτόματα το Bearer token
    provideHttpClient(withInterceptorsFromDi()),
    { provide: HTTP_INTERCEPTORS, useClass: MsalInterceptor, multi: true },

    // Ρυθμίσεις MSAL
    { provide: MSAL_INSTANCE, useValue: msalInstance },
    {
      provide: MSAL_GUARD_CONFIG,
      // Διόρθωση: LOGIN_SCOPES είναι ήδη array, όχι [LOGIN_SCOPES]
      useValue: { interactionType: InteractionType.Redirect, authRequest: { scopes: LOGIN_SCOPES } },
    },
    {
      provide: MSAL_INTERCEPTOR_CONFIG,
      useValue: {
        interactionType: InteractionType.Redirect,
        // Διόρθωση: LOGIN_SCOPES, όχι [LOGIN_SCOPES]. Αργότερα: [API_SCOPE]
        protectedResourceMap: new Map([[baseURL, LOGIN_SCOPES]]),
      },
    },

    // Τα services που κάνεις inject στα components
    MsalService,
    MsalGuard,
    MsalBroadcastService,

    // Το MSAL πρέπει να γίνει initialize πριν ξεκινήσει η εφαρμογή
    provideAppInitializer(() => {
      const instance = inject(MSAL_INSTANCE) as IPublicClientApplication;
      return instance.initialize();
    }),
  ],
};