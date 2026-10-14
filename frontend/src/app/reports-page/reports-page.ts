import { Component, ElementRef, ViewChild, computed, inject, signal } from '@angular/core';
import { DomSanitizer, SafeResourceUrl } from '@angular/platform-browser';
import { POWER_BI_REPORTS } from './powerbi_config';

type UrlStatus = 'ok' | 'empty' | 'invalid';

@Component({
  selector: 'app-reports-page',
  standalone: true,
  templateUrl: './reports-page.html',
  styleUrl: './reports-page.css',
})
export class ReportsPage {
  @ViewChild('frameWrap') frameWrap?: ElementRef<HTMLDivElement>;

  private sanitizer = inject(DomSanitizer);

  reports = POWER_BI_REPORTS;
  selectedId = signal(this.reports[0]?.id ?? '');
  isLoading = signal(true);

  selected = computed(() => this.reports.find((r) => r.id === this.selectedId()));

  urlStatus = computed<UrlStatus>(() => {
    const url = this.selected()?.embedUrl?.trim() ?? '';
    if (!url) return 'empty';
    return this.isPowerBiUrl(url) ? 'ok' : 'invalid';
  });

  // Επιτρέπονται μόνο URLs του Power BI, για λόγους ασφαλείας
  safeUrl = computed<SafeResourceUrl | null>(() => {
    if (this.urlStatus() !== 'ok') return null;
    return this.sanitizer.bypassSecurityTrustResourceUrl(this.selected()!.embedUrl.trim());
  });

  select(id: string): void {
    if (id === this.selectedId()) return;
    this.selectedId.set(id);
    this.isLoading.set(true);
  }

  onFrameLoad(): void {
    this.isLoading.set(false);
  }

  toggleFullscreen(): void {
    const el = this.frameWrap?.nativeElement;
    if (!el) return;
    if (document.fullscreenElement) {
      document.exitFullscreen();
    } else {
      el.requestFullscreen();
    }
  }

  private isPowerBiUrl(url: string): boolean {
    try {
      const u = new URL(url);
      return u.protocol === 'https:' && u.hostname.endsWith('.powerbi.com');
    } catch {
      return false;
    }
  }
}