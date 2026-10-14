import { Component, ElementRef, ViewChild, computed, inject, signal } from '@angular/core';
import { Observable } from 'rxjs';
import { HttpHelper } from '../http-helper';

type ChatMode = 'project' | 'general';

interface ChatMessage {
  id: number;
  sender: 'user' | 'bot';
  text: string;
  /** The mode the question was asked in (bot messages only). */
  mode?: ChatMode;
  /** True when the message reports a failure instead of an answer. */
  isError?: boolean;
}

interface ModeOption {
  value: ChatMode;
  label: string;
  description: string;
  placeholder: string;
}

type StarterIcon = 'volume' | 'speed' | 'sla' | 'causes' | 'monitoring';

interface StarterQuestion {
  category: string;
  icon: StarterIcon;
  /** Short text shown on the card */
  title: string;
  /** Full question sent to the assistant */
  question: string;
}

@Component({
  selector: 'app-home-page',
  standalone: true,
  templateUrl: './home-page.html',
  styleUrl: './home-page.css',
})
export class HomePage {
  @ViewChild('messageList') messageList?: ElementRef<HTMLDivElement>;
  @ViewChild('input') input?: ElementRef<HTMLTextAreaElement>;

  private myHttp = inject(HttpHelper);

  messages = signal<ChatMessage[]>([]);
  draft = signal('');
  isTyping = signal(false);
  mode = signal<ChatMode>('project');

  /** Empty state: no messages yet and nothing in progress */
  readonly isEmpty = computed(() => this.messages().length === 0 && !this.isTyping());

  // Τα datasets που διαβάζει ο assistant (εμφανίζονται κάτω από τον τίτλο)
  readonly datasets = ['Incidents', 'Assets', 'Teams', 'Monitoring events'];

  // Προαιρετικό: το χρονικό εύρος των δεδομένων, π.χ. 'January to June 2026'.
  // Άφησέ το null αν δεν θέλεις να εμφανίζεται.
  readonly dataCoverage: string | null = null;

  get heroSubtitle(): string {
    const base =
      'Explore incident trends, SLA performance, affected assets, team workload ' +
      'and the monitoring alerts behind each incident';
    return this.dataCoverage ? `${base}, for ${this.dataCoverage}.` : `${base}.`;
  }

  readonly modes: ModeOption[] = [
    {
      value: 'project',
      label: 'Incident data',
      description: 'Answers are computed from the curated incident data model.',
      placeholder: 'Ask about incidents, SLAs, services or teams...',
    },
    {
      value: 'general',
      label: 'General',
      description: "General mode answers from the model's own knowledge. Your incident data is not used.",
      placeholder: 'Ask a general question...',
    },
  ];

  readonly activeMode = computed(
    () => this.modes.find((m) => m.value === this.mode()) ?? this.modes[0],
  );

  // Έτοιμες ερωτήσεις: άλλαξε το κείμενο εδώ
  readonly starters: StarterQuestion[] = [
    {
      category: 'Volume',
      icon: 'volume',
      title: 'Incidents opened in May 2026',
      question: 'How many incidents were opened in May 2026?',
    },
    {
      category: 'Response time',
      icon: 'speed',
      title: 'Mean time to acknowledge in June 2026',
      question: 'What was the mean time to acknowledge incidents in June 2026, in minutes?',
    },
    {
      category: 'SLA',
      icon: 'sla',
      title: 'SLA compliance by severity across Q2 2026',
      question:
        'What was the SLA compliance rate per severity level for each month of Q2 2026?',
    },
    {
      category: 'Root causes',
      icon: 'causes',
      title: 'Slowest services to resolve P1 and P2 incidents',
      question:
        'Which three business services had the longest mean time to resolve for P1 and P2 incidents, and which team handled most of those incidents?',
    },
    {
      category: 'Monitoring',
      icon: 'monitoring',
      title: 'Alerts that preceded incidents on critical assets',
      question:
        'For incidents on Critical production assets, how many were preceded by a monitoring alert, and which metric triggered those alerts most often?',
    },
  ];

  private nextId = 1;

  setMode(mode: ChatMode): void {
    this.mode.set(mode);
    this.input?.nativeElement.focus();
  }

  onInput(event: Event): void {
    const el = event.target as HTMLTextAreaElement;
    this.draft.set(el.value);
    this.autoResize(el);
  }

  // Enter sends, Shift+Enter adds a new line
  onKeydown(event: KeyboardEvent): void {
    if (event.key === 'Enter' && !event.shiftKey) {
      event.preventDefault();
      this.send();
    }
  }

  // Αποστολή από το πλαίσιο κειμένου
  send(): void {
    const text = this.draft().trim();
    if (!text || this.isTyping()) return;

    // Clear the textbox
    this.draft.set('');
    if (this.input) {
      this.input.nativeElement.value = '';
      this.autoResize(this.input.nativeElement);
      this.input.nativeElement.focus();
    }

    this.sendText(text);
  }

  // Αποστολή από μια έτοιμη ερώτηση.
  // Οι έτοιμες ερωτήσεις αφορούν τα δεδομένα, οπότε γυρνάμε σε 'project' mode.
  askStarter(starter: StarterQuestion): void {
    if (this.isTyping()) return;
    this.mode.set('project');
    this.sendText(starter.question);
  }

  private sendText(text: string): void {
    const mode = this.mode();

    // Show the user's message right away
    this.addMessage({ sender: 'user', text });

    // Show the typing indicator while waiting for the server
    this.isTyping.set(true);
    this.scrollToBottom();

    const body = {
      question: text,
      role: 'role',
    };

    // Project -> postSendMessage, General -> postSendMessageGeneral
    const request$: Observable<any> =
      mode === 'project'
        ? this.myHttp.postSendMessage(body)
        : this.myHttp.postSendMessageGeneral(body);

    request$.subscribe({
      next: (res: any) => {
        this.isTyping.set(false);
        const answer: string | undefined = res?.['answer'];

        if (answer) {
          this.addMessage({ sender: 'bot', text: answer, mode });
        } else {
          this.addMessage({
            sender: 'bot',
            text: 'The assistant returned an empty response. Try rephrasing the question.',
            mode,
            isError: true,
          });
        }
      },
      error: (err) => {
        console.error(err);
        this.isTyping.set(false);
        this.addMessage({
          sender: 'bot',
          text: this.describeError(err),
          mode,
          isError: true,
        });
      },
    });
  }

  // Πιο χρήσιμα μηνύματα λάθους ανάλογα με το status code
  private describeError(err: any): string {
    const status: number | undefined = err?.status;
    if (status === 0) {
      return "The assistant service couldn't be reached. Check that the API is running, then try again.";
    }
    if (status === 401 || status === 403) {
      return 'Your session is not authorized for this request. Sign out and sign in again.';
    }
    if (status && status >= 500) {
      return 'The assistant service hit an error while answering. Try again in a moment.';
    }
    return "The question couldn't be answered. Try again or rephrase it.";
  }

  private addMessage(message: Omit<ChatMessage, 'id'>): void {
    this.messages.update((list) => [...list, { id: this.nextId++, ...message }]);
    this.scrollToBottom();
  }

  private scrollToBottom(): void {
    setTimeout(() => {
      const el = this.messageList?.nativeElement;
      if (el) el.scrollTo({ top: el.scrollHeight, behavior: 'smooth' });
    });
  }

  private autoResize(el: HTMLTextAreaElement): void {
    el.style.height = 'auto';
    el.style.height = Math.min(el.scrollHeight, 200) + 'px';
  }
}