// noteclarity.d.ts — NoteClarity Plugin API v1.0
declare const noteclarity: NoteClarityAPI;

interface NoteClarityAPI {
  readonly version: string;      // app version
  readonly apiVersion: string;   // "1.0"

  editor: {
    getText(): string;
    setText(text: string): void;
    getSelection(): { text: string; start: number; end: number };
    replaceSelection(text: string): void;
    getCursor(): number;
    setCursor(offset: number): void;
    insertAt(offset: number, text: string): void;
    getLineCount(): number;
    getFilePath(): string | null;
    getLanguage(): string;
    setLanguage(id: string): void;
  };

  commands: {
    register(id: string, callback: () => void): void;
    execute(id: string): void;
  };

  menu: {
    addItem(item: { title: string; command: string }): void;
  };

  ui: {
    // Registers a webview panel; `html` is the panel body loaded into a WKWebView.
    registerPanel(panel: {
      id: string;
      title: string;
      location: "left" | "right" | "bottom";
      html: string;
    }): PanelHandle;
    showNotification(message: string): void;
    showDialog(opts: { title: string; message: string; buttons?: string[] }): Promise<number>;
  };

  events: {
    on(event: NoteClarityEvent, cb: (payload: any) => void): void;
    off(event: NoteClarityEvent, cb: (payload: any) => void): void;
  };

  storage: {                    // per-plugin persisted key/value
    get(key: string): any;
    set(key: string, value: any): void;
  };

  fs: {                         // permission-gated; mediated by the host
    readFile(path: string): string;
    writeFile(path: string, data: string): void;
  };

  net: {                        // permission-gated
    fetch(url: string, opts?: { method?: string; headers?: Record<string,string>; body?: string }): Promise<{ status: number; body: string }>;
  };
}

type NoteClarityEvent =
  | "document.opened"
  | "document.changed"
  | "document.saved"
  | "selection.changed"
  | "language.changed";

interface PanelHandle {
  // Host <-> panel-webview messaging.
  postMessage(msg: any): void;                 // send to the panel's webview
  onMessage(cb: (msg: any) => void): void;     // receive from the panel's webview
  reveal(): void;
  dispose(): void;
}
