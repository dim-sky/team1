import { Component, ElementRef, ViewChild, inject, signal } from '@angular/core';
import { Observable } from 'rxjs';
import { HttpHelper } from '../http-helper';

interface ChatMessage {
  id: number;
  sender: 'user' | 'bot';
  text: string;
}

type ChatMode = 'project' | 'general';

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

  // Έτοιμες ερωτήσεις: άλλαξε το κείμενο εδώ
  suggestions: string[] = [
    'How many incidents were opened in May 2026?',
    'What was the mean time to acknowledge incidents in June 2026, in minutes?',
    'What was the SLA compliance rate per severity level for each month of Q2 2026',
    'Which three business services had the longest mean time to resolve for P1 and P2 incidents, and which team handled most of those incidents?',
    'For incidents on Critical production assets, how many were preceded by a monitoring alert, and which metric triggered those alerts most often?',
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

  // Αποστολή από μια έτοιμη ερώτηση
  askSuggestion(question: string): void {
    if (this.isTyping()) return;
    this.sendText(question);
  }

  private sendText(text: string): void {
    // Show the user's message right away
    this.addMessage('user', text);

    // Show the typing indicator while waiting for the server
    this.isTyping.set(true);
    this.scrollToBottom();

    const body = {
      question: text,
      role: 'role',
    };

    // Project -> /prompt, General -> /generalprompt
    const request$: Observable<any> =
      this.mode() === 'project'
        ? this.myHttp.postSendMessage(body)
        : this.myHttp.postSendMessageGeneral(body);

    request$.subscribe({
      next: (res: any) => {
        this.isTyping.set(false);
        this.addMessage('bot', res['answer']);
      },
      error: (err) => {
        console.error(err);
        this.isTyping.set(false);
        this.addMessage('bot', 'Sorry, something went wrong. Please try again.');
      },
    });
  }

  private addMessage(sender: 'user' | 'bot', text: string): void {
    this.messages.update((list) => [...list, { id: this.nextId++, sender, text }]);
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