import { ApplicationConfig, inject, provideAppInitializer, provideBrowserGlobalErrorListeners } from '@angular/core';
import { provideRouter } from '@angular/router';
import { provideHttpClient, withInterceptorsFromDi, HTTP_INTERCEPTORS } from '@angular/common/http';
import { PublicClientApplication, InteractionType, BrowserCacheLocation, IPublicClientApplication } from '@azure/msal-browser';
import {
  MSAL_INSTANCE, MSAL_GUARD_CONFIG, MSAL_INTERCEPTOR_CONFIG,
  MsalService, MsalGuard, MsalBroadcastService, MsalInterceptor
} from '@azure/msal-angular';

import { routes } from './app.routes';

const TENANT_ID = 'b1732512-60e5-48fb-92e8-8d6902ac1349';
const SPA_CLIENT_ID = '37815f98-bbed-4937-95a3-d0ca7960c989';
const LOGIN_SCOPES = ['User.Read'];
// Όταν φτιάξεις backend: const API_SCOPE = 'api://<api-client-id>/access_as_user';
// const API_SCOPE = 'api://<api-client-id>/access_as_user';  /// Να το βάλω μετά με το backend

const msalInstance = new PublicClientApplication({
  auth: {
    clientId: SPA_CLIENT_ID,
    authority: `https://login.microsoftonline.com/${TENANT_ID}`,
    redirectUri: window.location.origin,
    // redirectUri: 'http://localhost:4200',
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
      useValue: { interactionType: InteractionType.Redirect, authRequest: { scopes: [LOGIN_SCOPES] } },
      // Να γίνει API_SCOPE μετά???
    },
    {
      provide: MSAL_INTERCEPTOR_CONFIG,
      useValue: {
        interactionType: InteractionType.Redirect,
        protectedResourceMap: new Map([['http://localhost:8001/', [LOGIN_SCOPES]]]),
        // Να γίνει API_SCOPE μετά???
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