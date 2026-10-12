import { Component, ElementRef, ViewChild, inject, signal } from '@angular/core';
import { HttpHelper } from '../http-helper';

interface ChatMessage {
  id: number;
  sender: 'user' | 'bot';
  text: string;
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

  private nextId = 1;

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

  send(): void {
    const text = this.draft().trim();
    if (!text || this.isTyping()) return;

    // Show the user's message right away
    this.addMessage('user', text);

    // Clear the textbox
    this.draft.set('');
    if (this.input) {
      this.input.nativeElement.value = '';
      this.autoResize(this.input.nativeElement);
      this.input.nativeElement.focus();
    }

    // Show the typing indicator while waiting for the server
    this.isTyping.set(true);
    this.scrollToBottom();

    const body = {
      question: text,
      role: 'role',
    };

    this.myHttp.postSendMessage(body).subscribe({
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