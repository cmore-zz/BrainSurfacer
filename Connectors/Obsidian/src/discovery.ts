import { constants } from "node:fs";
import { access } from "node:fs/promises";
import { homedir } from "node:os";
import path from "node:path";
import { execFile } from "node:child_process";

export interface RunningApplication {
  pid: number;
  bundlePath: string;
}

export interface HelperTarget extends RunningApplication {
  command: string;
}

export interface DiscoveryEnvironment {
  now(): number;
  processLines(): Promise<string[]>;
  isProcessRunning(pid: number): boolean;
  isExecutable(candidate: string): Promise<boolean>;
}

export interface HelperDiscoveryOptions {
  configuredCommand?: string;
  cooldownMilliseconds?: number;
  environment?: DiscoveryEnvironment;
}

interface DiscoveryCache {
  checkedAt: number;
  target: HelperTarget | null;
}

const defaultEnvironment: DiscoveryEnvironment = {
  now: Date.now,
  processLines: readProcessLines,
  isProcessRunning(pid: number): boolean {
    try {
      process.kill(pid, 0);
      return true;
    } catch {
      return false;
    }
  },
  async isExecutable(candidate: string): Promise<boolean> {
    try {
      await access(candidate, constants.X_OK);
      return true;
    } catch {
      return false;
    }
  },
};

export class HelperDiscovery {
  private configuredCommand: string;
  private readonly cooldownMilliseconds: number;
  private readonly environment: DiscoveryEnvironment;
  private cache: DiscoveryCache | null = null;

  constructor(options: HelperDiscoveryOptions = {}) {
    this.configuredCommand = options.configuredCommand?.trim() ?? "";
    this.cooldownMilliseconds = options.cooldownMilliseconds ?? 10_000;
    this.environment = options.environment ?? defaultEnvironment;
  }

  setConfiguredCommand(command: string): void {
    this.configuredCommand = command.trim();
    this.clearCache();
  }

  clearCache(): void {
    this.cache = null;
  }

  async discover(force = false): Promise<HelperTarget | null> {
    const now = this.environment.now();
    if (
      !force
      && this.cache !== null
      && now - this.cache.checkedAt < this.cooldownMilliseconds
    ) {
      if (this.cache.target === null) {
        return null;
      }
      if (this.environment.isProcessRunning(this.cache.target.pid)) {
        return this.cache.target;
      }
      this.cache = null;
    }

    const applications = parseRunningApplications(
      await this.environment.processLines(),
    );
    const target = await this.selectTarget(applications);
    this.cache = { checkedAt: now, target };
    return target;
  }

  private async selectTarget(
    applications: RunningApplication[],
  ): Promise<HelperTarget | null> {
    if (applications.length === 0) {
      return null;
    }

    if (this.configuredCommand.length > 0) {
      const command = expandHome(this.configuredCommand);
      if (!path.isAbsolute(command) || !(await this.environment.isExecutable(command))) {
        return null;
      }
      const application = applications[0];
      return application === undefined ? null : { ...application, command };
    }

    for (const application of applications) {
      const command = path.join(
        application.bundlePath,
        "Contents",
        "Helpers",
        "brainsurfacer-context",
      );
      if (await this.environment.isExecutable(command)) {
        return { ...application, command };
      }
    }
    return null;
  }
}

export function parseRunningApplications(lines: string[]): RunningApplication[] {
  const applications: RunningApplication[] = [];
  const seen = new Set<string>();
  const expression = /^\s*(\d+)\s+(.+\.app)\/Contents\/MacOS\/BrainSurfacer(?:\s.*)?$/;
  for (const line of lines) {
    const match = expression.exec(line);
    const pidText = match?.[1];
    const bundlePath = match?.[2];
    if (pidText === undefined || bundlePath === undefined) {
      continue;
    }
    const pid = Number.parseInt(pidText, 10);
    const key = `${pid}\u0000${bundlePath}`;
    if (!Number.isSafeInteger(pid) || pid <= 0 || seen.has(key)) {
      continue;
    }
    seen.add(key);
    applications.push({ pid, bundlePath });
  }
  return applications;
}

function expandHome(candidate: string): string {
  if (candidate === "~") {
    return homedir();
  }
  return candidate.startsWith("~/")
    ? path.join(homedir(), candidate.slice(2))
    : candidate;
}

function readProcessLines(): Promise<string[]> {
  return new Promise((resolve) => {
    execFile(
      "/bin/ps",
      ["-ww", "-axo", "pid=,command="],
      { encoding: "utf8", maxBuffer: 2 * 1_024 * 1_024 },
      (error, stdout) => {
        resolve(error === null ? stdout.split(/\r?\n/u) : []);
      },
    );
  });
}
