import { createHash } from "node:crypto";
import path from "node:path";
import {
  FileSystemAdapter,
  MarkdownView,
  Notice,
  Plugin,
  PluginSettingTab,
  Setting,
  TFile,
  type WorkspaceLeaf,
} from "obsidian";
import { HelperDiscovery } from "./discovery";
import {
  buildSnapshot,
  encodePayload,
  type WorkspaceDocument,
} from "./snapshot";
import { ContextTransport } from "./transport";

interface BrainSurfacerSettings {
  helperPath: string;
}

const defaultSettings: BrainSurfacerSettings = {
  helperPath: "",
};
const debounceMilliseconds = 250;
const timeToLive = 60;
const heartbeatMilliseconds = 30_000;

export default class BrainSurfacerPlugin extends Plugin {
  settings: BrainSurfacerSettings = defaultSettings;

  private transport: ContextTransport | null = null;
  private vaultRoot: string | null = null;
  private providerID = "md.obsidian.BrainSurfacer";
  private debounceTimer: number | null = null;
  private pendingReport = false;
  private pendingForce = false;
  private drainingReports = false;
  private unloading = false;
  private lastPayload: string | null = null;
  private lastError: string | null = null;

  async onload(): Promise<void> {
    await this.loadSettings();
    const adapter = this.app.vault.adapter;
    if (!(adapter instanceof FileSystemAdapter)) {
      this.lastError = "BrainSurfacer requires a local filesystem vault.";
      console.warn(this.lastError);
      return;
    }

    this.vaultRoot = adapter.getBasePath();
    this.providerID = providerIDForVault(this.vaultRoot);
    this.transport = new ContextTransport(
      new HelperDiscovery({ configuredCommand: this.settings.helperPath }),
    );
    this.addSettingTab(new BrainSurfacerSettingTab(this));
    this.addCommand({
      id: "report-live-context-now",
      name: "Report live context now",
      callback: () => {
        void this.reportInteractively();
      },
    });

    const schedule = (): void => {
      this.scheduleReport();
    };
    this.registerEvent(this.app.workspace.on("active-leaf-change", schedule));
    this.registerEvent(this.app.workspace.on("file-open", schedule));
    this.registerEvent(this.app.workspace.on("layout-change", schedule));
    this.registerEvent(this.app.workspace.on("window-open", schedule));
    this.registerEvent(this.app.workspace.on("window-close", schedule));
    this.registerEvent(this.app.vault.on("rename", schedule));
    this.registerEvent(this.app.vault.on("delete", schedule));
    this.registerEvent(
      this.app.workspace.on("quit", (tasks) => {
        tasks.addPromise(this.clearContext());
      }),
    );

    this.app.workspace.onLayoutReady(() => {
      if (this.unloading) {
        return;
      }
      this.registerInterval(
        window.setInterval(() => {
          this.queueReport(true);
        }, heartbeatMilliseconds),
      );
      this.queueReport(true);
    });
  }

  onunload(): void {
    this.unloading = true;
    if (this.debounceTimer !== null) {
      window.clearTimeout(this.debounceTimer);
      this.debounceTimer = null;
    }
    void this.clearContext();
  }

  async updateHelperPath(helperPath: string): Promise<void> {
    this.settings.helperPath = helperPath.trim();
    await this.saveData(this.settings);
    this.transport?.setConfiguredCommand(this.settings.helperPath);
    this.lastPayload = null;
    this.queueReport(true);
  }

  private async loadSettings(): Promise<void> {
    this.settings = Object.assign({}, defaultSettings, await this.loadData());
  }

  private scheduleReport(force = false): void {
    this.pendingForce ||= force;
    if (this.debounceTimer !== null) {
      window.clearTimeout(this.debounceTimer);
    }
    this.debounceTimer = window.setTimeout(() => {
      this.debounceTimer = null;
      const shouldForce = this.pendingForce;
      this.pendingForce = false;
      this.queueReport(shouldForce);
    }, debounceMilliseconds);
  }

  private queueReport(force: boolean): void {
    if (this.unloading) {
      return;
    }
    this.pendingReport = true;
    this.pendingForce ||= force;
    if (!this.drainingReports) {
      void this.drainReports();
    }
  }

  private async drainReports(): Promise<void> {
    this.drainingReports = true;
    try {
      while (this.pendingReport && !this.unloading) {
        const force = this.pendingForce;
        this.pendingReport = false;
        this.pendingForce = false;
        await this.report(force);
      }
    } finally {
      this.drainingReports = false;
    }
  }

  private async report(force: boolean): Promise<boolean> {
    const transport = this.transport;
    if (transport === null) {
      return false;
    }
    const payload = encodePayload(
      this.providerID,
      timeToLive,
      buildSnapshot(this.workspaceDocuments()),
    );
    if (!force && payload === this.lastPayload) {
      return true;
    }
    try {
      const invoked = await transport.send(payload);
      if (invoked) {
        this.lastPayload = payload;
        this.lastError = null;
      }
      return invoked;
    } catch (error) {
      this.lastPayload = null;
      this.lastError = error instanceof Error ? error.message : String(error);
      console.warn("BrainSurfacer context update failed:", error);
      return false;
    }
  }

  private async reportInteractively(): Promise<void> {
    this.transport?.clearDiscoveryCache();
    const reported = await this.report(true);
    if (reported) {
      new Notice("Reported current Obsidian context to BrainSurfacer.");
    } else {
      new Notice(
        this.lastError
          ?? "BrainSurfacer is not running or its context helper was not found.",
      );
    }
  }

  private workspaceDocuments(): WorkspaceDocument[] {
    const vaultRoot = this.vaultRoot;
    if (vaultRoot === null) {
      return [];
    }
    const activePath = this.app.workspace
      .getActiveViewOfType(MarkdownView)?.file?.path;
    const documents: WorkspaceDocument[] = [];
    for (const leaf of this.app.workspace.getLeavesOfType("markdown")) {
      const relativePath = markdownPath(leaf);
      if (relativePath === null) {
        continue;
      }
      const file = this.app.vault.getAbstractFileByPath(relativePath);
      if (!(file instanceof TFile) || file.extension.toLowerCase() !== "md") {
        continue;
      }
      const absolutePath = absoluteVaultPath(vaultRoot, file.path);
      if (absolutePath === null) {
        continue;
      }
      documents.push({
        path: absolutePath,
        selected: file.path === activePath,
        visible: leaf.view.containerEl.isShown(),
      });
    }
    return documents;
  }

  private async clearContext(): Promise<void> {
    const transport = this.transport;
    if (transport === null) {
      return;
    }
    try {
      await transport.send(
        encodePayload(this.providerID, timeToLive, {
          selected: [],
          visible: [],
          open: [],
        }),
      );
    } catch {
      // Context expires automatically if best-effort shutdown cleanup cannot run.
    }
    this.lastPayload = null;
  }
}

class BrainSurfacerSettingTab extends PluginSettingTab {
  constructor(private readonly brainsurfacer: BrainSurfacerPlugin) {
    super(brainsurfacer.app, brainsurfacer);
  }

  display(): void {
    this.containerEl.empty();
    new Setting(this.containerEl)
      .setName("Context helper")
      .setDesc(
        "Optional absolute path to brainsurfacer-context. Leave empty to discover it inside a running BrainSurfacer app.",
      )
      .addText((text) => {
        text
          .setPlaceholder("Discover automatically")
          .setValue(this.brainsurfacer.settings.helperPath)
          .onChange(async (value) => {
            await this.brainsurfacer.updateHelperPath(value);
          });
      });
  }
}

function markdownPath(leaf: WorkspaceLeaf): string | null {
  if (leaf.view instanceof MarkdownView) {
    return leaf.view.file?.path ?? null;
  }
  const state = leaf.getViewState();
  if (state.type !== "markdown" || !isRecord(state.state)) {
    return null;
  }
  const file = state.state.file;
  return typeof file === "string" && file.length > 0 ? file : null;
}

function absoluteVaultPath(vaultRoot: string, relativePath: string): string | null {
  const root = path.resolve(vaultRoot);
  const candidate = path.resolve(root, relativePath);
  return candidate === root || candidate.startsWith(`${root}${path.sep}`)
    ? candidate
    : null;
}

function providerIDForVault(vaultRoot: string): string {
  const digest = createHash("sha256")
    .update(path.resolve(vaultRoot))
    .digest("hex")
    .slice(0, 16);
  return `md.obsidian.BrainSurfacer.${digest}`;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}
