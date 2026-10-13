import { Routes } from '@angular/router';
import { HomePage } from './home-page/home-page';
import { LandingPage } from './landing-page/landing-page';

export const routes: Routes = [
  { path: '', component: LandingPage, pathMatch: 'full' },
  { path: 'home', component: HomePage },
  { path: '**', redirectTo: '' },
];