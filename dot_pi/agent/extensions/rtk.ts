import { spawnSync } from "node:child_process";
import {
	createBashTool,
	createLocalBashOperations,
	getAgentDir,
	getShellConfig,
	SettingsManager,
	type BashOperations,
	type ExtensionAPI,
	type ExtensionContext,
} from "@earendil-works/pi-coding-agent";

const quote = (value: string) => `'${value.replace(/'/g, "'\\''")}'`;

export default function (pi: ExtensionAPI) {
	const settingsFor = (ctx: ExtensionContext) =>
		SettingsManager.create(ctx.cwd, getAgentDir(), { projectTrusted: ctx.isProjectTrusted() });

	const operationsFor = (shellPath?: string): BashOperations => {
		const local = createLocalBashOperations({ shellPath });
		const shell = getShellConfig(shellPath).shell;
		return {
			async exec(command, cwd, options) {
				if (options.signal?.aborted) throw new Error("aborted");
				const rewrite = spawnSync("rtk", ["rewrite", command], {
					cwd,
					env: options.env,
					encoding: "utf8",
					timeout: 2000,
				});
				// RTK 0.51.0 returns 3 for successful rewrites (its help says 0).
				const candidate = rewrite.stdout?.trim();
				const script = !rewrite.error && [0, 3].includes(rewrite.status ?? -1) && /^rtk\s/.test(candidate)
					? candidate
					: command;
				// Wrap the complete script, including Pi's setup prefix. Unsupported shell
				// syntax stays intact; supported commands also get RTK's native filters.
				return local.exec(`exec rtk run --shell ${quote(shell)} -c ${quote(script)}`, cwd, options);
			},
		};
	};

	pi.registerTool({
		...createBashTool(process.cwd()),
		async execute(id, params, signal, onUpdate, ctx) {
			const settings = settingsFor(ctx);
			const tool = createBashTool(ctx.cwd, {
				operations: operationsFor(settings.getShellPath()),
				commandPrefix: settings.getShellCommandPrefix(),
			});
			return tool.execute(id, params, signal, onUpdate, ctx);
		},
	});

	pi.on("user_bash", (_event, ctx) => ({
		operations: operationsFor(settingsFor(ctx).getShellPath()),
	}));
}
