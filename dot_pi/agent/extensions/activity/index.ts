import { FooterComponent, type ExtensionAPI, type ExtensionContext, type Theme } from "@earendil-works/pi-coding-agent";
import {
	Container, Input, MouseRegion, SelectList, getKeybindings, matchesKey, stripTerminalSequences, truncateToWidth,
	visibleWidth, wrapTextWithAnsi, type Component, type TUI, type TuiMouseEvent,
} from "@earendil-works/pi-tui";

type Kind = "process" | "subagent";
export type Activity = { kind: Kind; id: string; title: string; state: string; detail?: string };
export type Result = { output?: string; state?: string; error?: string };
type Action = "read" | "send" | "stop";
type Request = (item: Activity, action: Action, text?: string) => Promise<Result>;

// Backend strings are data, not terminal escape sequences (including OSC links).
function plain(value: string): string {
	return stripTerminalSequences(value).replace(/\t/g, "    ").replace(/[\x00-\x08\x0b-\x1f\x7f-\x9f]/g, "");
}
function label(item: Activity): string {
	return plain(`${item.kind === "process" ? "job" : "agent"} ${item.title} [${item.state}]`).replace(/\s+/g, " ");
}
export function parseUpdate(value: unknown): { kind: Kind; items: Activity[] } | undefined {
	if (!value || typeof value !== "object") return;
	const { kind, items } = value as Record<string, unknown>;
	if ((kind !== "process" && kind !== "subagent") || !Array.isArray(items)) return;
	const seen = new Set<string>();
	const parsed: Activity[] = [];
	for (const item of items) {
		if (!item || typeof item !== "object" || typeof item.id !== "string" || !item.id ||
			typeof item.title !== "string" || typeof item.state !== "string" ||
			(item.detail !== undefined && typeof item.detail !== "string") || seen.has(item.id)) return;
		seen.add(item.id);
		parsed.push({ kind, id: item.id, title: item.title, state: item.state, detail: item.detail });
	}
	return { kind, items: parsed };
}
function parseResult(value: unknown): Result {
	if (!value || typeof value !== "object") return { error: "Invalid activity response" };
	const result = value as Record<string, unknown>;
	for (const key of ["output", "state", "error"]) {
		if (result[key] !== undefined && typeof result[key] !== "string") return { error: "Invalid activity response" };
	}
	return { output: result.output as string | undefined, state: result.state as string | undefined, error: result.error as string | undefined };
}
function line(text: string): Component {
	return { render: (width) => [truncateToWidth(text, Math.max(0, width), "")], invalidate() {} };
}
function clickable(child: Component, click: () => void, left = 0): MouseRegion {
	return new MouseRegion(child, (event: TuiMouseEvent) => {
		if (event.button !== "left" || event.x < left || event.x >= event.width) return;
		if (event.type === "click") click();
		if (event.type === "click" || event.type === "press" || event.type === "release") return { handled: true };
	});
}

// Active work first, reusable idle agents next, retained terminal records last.
function rank(item: Activity): number {
	return /^(idle|settled)$/i.test(item.state) ? 1 :
		/^(done|completed|exited|stopped|failed|error|lost|closed|archived)$/i.test(item.state) ? 2 : 0;
}

/** Decorate only the native cwd row; leave model, usage and extension statuses intact.
 * Pi routes MouseRegion events only in fullscreen mode; /subagents works in both modes.
 */
export class ActivityFooter extends Container {
	constructor(
		private readonly footer: Component, private readonly items: () => Activity[],
		private readonly theme: Theme, private readonly open: () => void,
	) { super(); }

	override invalidate(): void { super.invalidate(); this.footer.invalidate(); }
	override render(width: number): string[] {
		this.clear();
		if (width < 1) return [];
		const rows = this.footer.render(width);
		if (width < 3 || !rows.length) return rows;
		const items = this.items().filter(item => item.kind === "subagent");
		const working = items.filter(item => rank(item) === 0).length;
		const text = truncateToWidth(`Subagents ${working} ▸`, Math.floor(width / 2), "…");
		const left = width - visibleWidth(text);
		const cwd = truncateToWidth(rows[0], Math.max(0, left - 1), "…");
		this.addChild(clickable(line(cwd + " ".repeat(left - visibleWidth(cwd)) + this.theme.fg("accent", text)), this.open));
		for (const row of rows.slice(1)) this.addChild(line(row));
		return super.render(width);
	}
}

/** Shared frame owns both visible borders and the matching mouse-coordinate inset. */
class ActivityWindow extends Container {
	private outerWidth = 80;
	private renderedHeight = 0;
	constructor(protected readonly theme: Theme, protected readonly tui: TUI, private readonly maxHeight: number) { super(); }
	private outerHeight(): number { return Math.max(1, Math.min(this.maxHeight, this.tui.terminal.rows - 2)); }
	private bordered(): boolean { return this.outerWidth >= 3 && this.outerHeight() >= 3; }
	protected height(): number { return this.outerHeight() - (this.bordered() ? 2 : 0); }
	protected beginRender(width: number): number {
		this.clear();
		this.outerWidth = width;
		return Math.max(0, width - (this.bordered() ? 2 : 0));
	}
	protected finishRender(width: number): string[] {
		const rows = super.render(width).slice(0, this.height()).map(row => truncateToWidth(row, width, ""));
		if (!this.bordered()) { this.renderedHeight = rows.length; return rows; }
		const edge = (text: string) => this.theme.fg("accent", text);
		const result = [edge(`╭${"─".repeat(width)}╮`),
			...rows.map(row => edge("│") + row + " ".repeat(Math.max(0, width - visibleWidth(row))) + edge("│")),
			edge(`╰${"─".repeat(width)}╯`)];
		this.renderedHeight = result.length;
		return result;
	}
	override handleMouse(event: TuiMouseEvent) {
		if (!this.bordered()) return super.handleMouse(event);
		if (event.x < 1 || event.x >= this.outerWidth - 1 || event.y < 1 || event.y >= this.renderedHeight - 1) return;
		return super.handleMouse({ ...event, x: event.x - 1, y: event.y - 1, width: event.width - 2, height: this.renderedHeight - 2 });
	}
}

/** Search and native selection stay inside a bounded overlay, never below the prompt. */
export class ActivityPicker extends ActivityWindow {
	private readonly input = new Input({ placeholder: "Search agents, tasks, states…", placeholderStyle: s => this.theme.fg("dim", s) });
	private list?: SelectList;
	private signature = "";
	private query = "";
	private hasFocus = false;
	get focused(): boolean { return this.hasFocus; }
	set focused(value: boolean) { this.hasFocus = value; this.input.focused = value; }

	constructor(
		private readonly items: () => Activity[], theme: Theme, tui: TUI,
		private readonly title: string, private readonly done: (item?: Activity) => void,
	) { super(theme, tui, 22); }
	private selection(): SelectList {
		const query = this.input.getValue().trim().toLowerCase();
		const words = query.split(/\s+/).filter(Boolean);
		const all = this.items().slice().sort((a, b) => rank(a) - rank(b));
		const entries = all.filter(item => words.every(word => plain(`${label(item)} ${item.id} ${item.detail ?? ""}`).toLowerCase().includes(word)));
		const signature = JSON.stringify([entries, query, this.height()]);
		if (signature !== this.signature) {
			const selected = query === this.query ? this.list?.getSelectedItem()?.value : undefined;
			this.signature = signature;
			this.query = query;
			this.list = new SelectList(entries.map(item => ({ value: `${item.kind}:${item.id}`, label: label(item), description: plain(item.detail ?? "").replace(/\s+/g, " ") })), Math.max(1, this.height() - 4), {
				selectedPrefix: s => this.theme.fg("accent", s), selectedText: s => this.theme.fg("accent", s),
				description: s => this.theme.fg("muted", s), scrollInfo: s => this.theme.fg("dim", s),
				noMatch: () => this.theme.fg("muted", all.length ? "No matching activity" : "No activity yet"),
			});
			this.list.setSelectedIndex(Math.max(0, entries.findIndex(item => `${item.kind}:${item.id}` === selected)));
			this.list.onSelect = choice => {
				const item = this.items().find(item => `${item.kind}:${item.id}` === choice.value);
				if (item) this.done(item);
			};
			this.list.onCancel = () => this.done();
		}
		return this.list!;
	}
	handleInput(data: string): void {
		const keys = getKeybindings();
		if ((["tui.select.cancel", "tui.select.confirm", "tui.select.up", "tui.select.down"] as const).some(action => keys.matches(data, action))) this.selection().handleInput(data);
		else this.input.handleInput(data);
		this.tui.requestRender();
	}
	override render(width: number): string[] {
		width = this.beginRender(width);
		if (width < 1) return [];
		const height = this.height();
		const entries = this.items();
		const active = entries.filter(item => rank(item) === 0).length;
		this.addChild(line(this.theme.fg("accent", `${this.title} (${entries.length}) · ${active} active · ${entries.length - active} history`)));
		if (height > 1) this.addChild(this.input);
		if (height > 2) this.addChild(this.selection());
		if (height > 4) this.addChild(line(this.theme.fg("dim", "Type to search · ↑↓ / click open · Esc close")));
		return this.finishRender(width);
	}
}

/** One interaction, no timer or backend ownership. A single extension timer refreshes this view. */
export class ActivityPanel extends ActivityWindow {
	private readonly input = new Input({ placeholder: "Text → Enter to send / steer", placeholderStyle: (s) => this.theme.fg("dim", s) });
	private output = "Loading…";
	private state: string;
	private message = "";
	private reading = false;
	private acting = false;
	private closed = false;
	private scroll = 0;
	private page = 1;
	private hasFocus = false;
	private get readOnly(): boolean { return rank({ ...this.item, state: this.state }) === 2; }
	get focused(): boolean { return this.hasFocus; }
	set focused(value: boolean) { this.hasFocus = value; this.input.focused = value && !this.readOnly; }

	constructor(
		private readonly item: Activity, theme: Theme, tui: TUI,
		private readonly request: Request, private readonly done: () => void,
	) {
		super(theme, tui, 26);
		this.state = item.state;
		this.input.onSubmit = (text) => { if (text.trim()) void this.act("send", text); };
	}
	close(): void {
		if (this.closed) return;
		this.closed = true;
		this.done();
	}
	dispose(): void { this.closed = true; }
	async refresh(): Promise<void> {
		if (this.closed || this.reading) return;
		this.reading = true;
		try {
			const result = await this.request(this.item, "read");
			if (this.closed) return;
			if (result.output !== undefined) this.output = plain(result.output.slice(-100_000));
			if (result.state !== undefined) this.state = result.state;
			this.message = result.error ?? "";
		} finally {
			this.reading = false;
			if (!this.closed) this.tui.requestRender();
		}
	}
	private async act(action: "send" | "stop", text?: string): Promise<void> {
		if (this.closed || this.acting || this.readOnly) return;
		this.acting = true;
		this.message = action === "send" ? "Sending…" : "Stopping…";
		this.tui.requestRender();
		try {
			const result = await this.request(this.item, action, text);
			if (this.closed) return;
			this.message = result.error ?? (action === "send" ? "Sent" : "Stop requested");
			if (!result.error && action === "send") this.input.setValue("");
			if (result.state !== undefined) this.state = result.state;
			if (result.output !== undefined) this.output = plain(result.output.slice(-100_000));
		} finally {
			this.acting = false;
			if (!this.closed) this.tui.requestRender();
		}
	}
	handleInput(data: string): void {
		if (matchesKey(data, "escape")) this.close();
		else if (matchesKey(data, "ctrl+r")) void this.refresh();
		else if (matchesKey(data, "ctrl+x")) void this.act("stop");
		else if (matchesKey(data, "pageUp")) this.scroll += this.page;
		else if (matchesKey(data, "pageDown")) this.scroll = Math.max(0, this.scroll - this.page);
		else if (!this.readOnly) this.input.handleInput(data);
		this.tui.requestRender();
	}
	override render(width: number): string[] {
		width = this.beginRender(width);
		if (width < 1) return [];
		const height = this.height();
		const rows = wrapTextWithAnsi(this.output, width);
		this.page = Math.max(1, height - 5);
		this.scroll = Math.min(this.scroll, Math.max(0, rows.length - this.page));
		const end = Math.max(0, rows.length - this.scroll);
		const title = plain(`${this.item.kind}: ${this.item.title} [${this.state}]`).replace(/\s+/g, " ");
		this.addChild(line(this.theme.fg("accent", title)));
		if (height > 2) this.addChild(line(this.theme.fg("dim", plain(this.message || this.item.detail || (this.readOnly ? "Saved conversation · PgUp/PgDn scroll" : "Live local output · PgUp/PgDn scroll")).replace(/\s+/g, " "))));
		if (height > 3) {
			for (const row of rows.slice(Math.max(0, end - this.page), end)) this.addChild(line(row));
		}
		const controls = this.readOnly ? "[Refresh Ctrl+R]  [Back Esc]" : "[Refresh Ctrl+R]  [Stop Ctrl+X]  [Back Esc]";
		if (height > 4) this.addChild(new MouseRegion(line(this.theme.fg("muted", controls)), (event) => {
			if (event.button !== "left" || event.x < 0 || event.x >= visibleWidth(controls) ||
				(event.x >= 16 && event.x < 18) || (!this.readOnly && event.x >= 31 && event.x < 33)) return;
			if (event.type === "click") {
				if (event.x < 16) void this.refresh();
				else if (!this.readOnly && event.x < 31) void this.act("stop");
				else this.close();
			}
			if (["click", "press", "release"].includes(event.type)) return { handled: true };
		}));
		if (height > 1) this.addChild(this.readOnly ? line(this.theme.fg("dim", "Read-only history · no worker running")) : this.input);
		return this.finishRender(width);
	}
}

export default function activityExtension(pi: ExtensionAPI): void {
	const lists = new Map<Kind, Activity[]>();
	const pending = new Set<(result: Result) => void>();
	let ctx: ExtensionContext | undefined;
	let timer: ReturnType<typeof setInterval> | undefined;
	let unsubscribe: (() => void) | undefined;
	let tui: TUI | undefined;
	let footerInstalled = false;
	let panel: ActivityPanel | undefined;
	let closePicker: (() => void) | undefined;
	let interacting = false;
	let generation = 0;
	const items = () => [...lists.values()].flat();
	const refresh = () => { try { pi.events.emit("activity:refresh", {}); } catch { /* Backend reports its own errors. */ } };
	const request: Request = (item, action, text) => new Promise((resolve) => {
		let settled = false;
		const finish = (result: Result) => {
			if (settled) return;
			settled = true;
			clearTimeout(timeout);
			pending.delete(finish);
			resolve(result);
		};
		const timeout = setTimeout(() => finish({ error: "Activity backend did not respond (5s). Try Refresh." }), 5000);
		pending.add(finish);
		try {
			pi.events.emit("activity:request", { kind: item.kind, id: item.id, action, ...(text === undefined ? {} : { text }), respond: (value: unknown) => finish(parseResult(value)) });
		} catch (error) { finish({ error: String(error) }); }
	});

	async function open(kind?: Kind): Promise<void> {
		if (!ctx?.hasUI || interacting) return;
		const current = ctx;
		const version = generation;
		const available = () => items().filter(item => !kind || item.kind === kind);
		const title = kind === "subagent" ? "Subagents" : "Background activity";
		interacting = true;
		try {
			while (version === generation) {
				refresh();
				let selected: Activity | undefined;
				if (current.mode === "tui") {
					selected = await current.ui.custom<Activity | undefined>((terminal, theme, _keys, done) => {
						closePicker = () => done(undefined);
						return new ActivityPicker(available, theme, terminal, title, done);
					}, { overlay: true, overlayOptions: { anchor: "center", width: "90%" } });
					closePicker = undefined;
				} else {
					const entries = available();
					if (!entries.length) { current.ui.notify("No background activity", "info"); return; }
					const options = entries.map((entry, i) => `${i + 1}. ${label(entry)} (${plain(entry.id)})`);
					const choice = await current.ui.select(title, options);
					selected = entries[options.indexOf(choice ?? "")];
				}
				if (!selected || version !== generation) return;
				if (current.mode === "tui") {
					await current.ui.custom<void>((terminal, theme, _keys, done) => {
						panel = new ActivityPanel(selected!, theme, terminal, request, done);
						void panel.refresh();
						return panel;
					}, { overlay: true, overlayOptions: { anchor: "center", width: "90%" } });
					panel = undefined;
				} else {
					// RPC supports dialogs, but not custom terminal components. No automatic reads here.
					while (version === generation) {
						const result = await request(selected, "read");
						if (version !== generation) return;
						const readOnly = rank({ ...selected, state: result.state ?? selected.state }) === 2;
						const actions = readOnly ? ["Refresh", "Back"] : ["Refresh", "Send / steer", "Stop", "Back"];
						const action = await current.ui.select(`${label(selected)}\n${plain(result.error ?? result.output ?? "No output").slice(-16_000)}`, actions);
						if (readOnly && action && !actions.includes(action)) continue;
						if (version !== generation || !action || action === "Back") break;
						if (action === "Send / steer") {
							const text = await current.ui.input("Send prompt / steer activity");
							if (version !== generation) return;
							if (text?.trim()) {
								const response = await request(selected, "send", text);
								if (version === generation) current.ui.notify(response.error ?? "Sent", response.error ? "error" : "info");
							}
						} else if (action === "Stop") {
							const response = await request(selected, "stop");
							if (version === generation) current.ui.notify(response.error ?? "Stop requested", response.error ? "error" : "info");
						}
					}
				}
			}
		} catch (error) {
			if (version === generation) current.ui.notify(`Activity: ${String(error)}`, "error");
		} finally {
			if (version === generation) { panel = undefined; closePicker = undefined; interacting = false; }
		}
	}
	function cleanup(): void {
		generation++;
		if (timer) clearInterval(timer);
		timer = undefined;
		unsubscribe?.();
		unsubscribe = undefined;
		panel?.close();
		panel = undefined;
		closePicker?.();
		closePicker = undefined;
		for (const finish of pending) finish({ error: "Activity UI closed" });
		if (ctx?.mode === "tui" && footerInstalled) ctx.ui.setFooter(undefined);
		footerInstalled = false;
		ctx = undefined;
		tui = undefined;
		interacting = false;
		lists.clear();
	}
	pi.on("session_start", (_event, context) => {
		cleanup();
		ctx = context;
		unsubscribe = pi.events.on("activity:update", (value: unknown) => {
			const update = parseUpdate(value);
			if (!update) return;
			const previous = lists.get(update.kind);
			if (JSON.stringify(previous) === JSON.stringify(update.items)) return;
			lists.set(update.kind, update.items);
			tui?.requestRender();
		});
		if (context.mode === "tui") {
			// Capture the existing exported footer before setFooter replaces its container.
			// Public component children work in both regular and fullscreen renderers.
			let nativeFooter: FooterComponent | undefined;
			context.ui.setWidget("activity", (terminal) => {
				const components = [...terminal.children];
				while (components.length) {
					const component = components.pop()!;
					if (component instanceof FooterComponent) { nativeFooter = component; break; }
					if (component instanceof Container) components.push(...component.children);
				}
				return { render: () => [], invalidate() {} };
			}, { placement: "belowEditor" });
			context.ui.setWidget("activity", undefined);
			if (nativeFooter) {
				const footer = nativeFooter;
				context.ui.setFooter((terminal, theme) => {
					tui = terminal;
					return new ActivityFooter(footer, items, theme, () => { void open("subagent"); });
				});
				footerInstalled = true;
			} else context.ui.notify("Built-in footer unavailable; use /subagents to open the picker.", "warning");
			timer = setInterval(() => { refresh(); void panel?.refresh(); }, 1000);
			timer.unref?.();
		}
		refresh();
	});
	pi.on("session_shutdown", cleanup);
	pi.registerCommand("activity", { description: "Background jobs and subagents: output, send / steer, stop", handler: async () => open() });
	pi.registerCommand("subagents", { description: "Pick a subagent to view its conversation, send / steer, or stop", handler: async () => open("subagent") });
}
