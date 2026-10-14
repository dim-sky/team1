import { Routes } from '@angular/router';
import { HomePage } from './home-page/home-page';
import { LandingPage } from './landing-page/landing-page';
import { ReportsPage } from './reports-page/reports-page';
import { ContactPage } from './contact-page/contact-page';

export const routes: Routes = [
  { path: '', component: LandingPage, pathMatch: 'full' },
  { path: 'home', component: HomePage },
  { path: 'report', component: ReportsPage },
  { path: 'contact', component: ContactPage },
  { path: '**', redirectTo: '' },
];