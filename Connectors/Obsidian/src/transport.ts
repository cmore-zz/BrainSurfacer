import { spawn } from "node:child_process";
import { HelperDiscovery, type HelperTarget } from "./discovery";

const maximumErrorBytes = 8_192;

export class ContextTransport {
  private delivery: Promise<void> = Promise.resolve();

  constructor(private readonly discovery: HelperDiscovery) {}

  clearDiscoveryCache(): void {
    this.discovery.clearCache();
  }

  setConfiguredCommand(command: string): void {
    this.discovery.setConfiguredCommand(command);
  }

  send(payload: string): Promise<boolean> {
    const operation = this.delivery.then(() => this.deliver(payload));
    this.delivery = operation.then(
      () => undefined,
      () => undefined,
    );
    return operation;
  }

  private async deliver(payload: string): Promise<boolean> {
    const target = await this.discovery.discover();
    if (target === null) {
      return false;
    }
    try {
      await invokeHelper(target, payload);
      return true;
    } catch (error) {
      this.discovery.clearCache();
      throw error;
    }
  }
}

function invokeHelper(target: HelperTarget, payload: string): Promise<void> {
  return new Promise((resolve, reject) => {
    const child = spawn(
      target.command,
      helperArguments(target),
      { stdio: ["pipe", "ignore", "pipe"] },
    );
    const errorChunks: Buffer[] = [];
    let errorBytes = 0;

    child.stderr.on("data", (chunk: Buffer) => {
      if (errorBytes >= maximumErrorBytes) {
        return;
      }
      const remaining = maximumErrorBytes - errorBytes;
      const bounded = chunk.subarray(0, remaining);
      errorChunks.push(bounded);
      errorBytes += bounded.byteLength;
    });
    child.stdin.on("error", () => {
      // The process-level error or nonzero close status provides the diagnostic.
    });
    child.once("error", reject);
    child.once("close", (status, signal) => {
      if (status === 0) {
        resolve();
        return;
      }
      const diagnostic = Buffer.concat(errorChunks).toString("utf8").trim();
      reject(new Error(diagnostic.length > 0 ? diagnostic : closeMessage(status, signal)));
    });
    child.stdin.end(payload, "utf8");
  });
}

export function helperArguments(target: HelperTarget): string[] {
  return [
    "--process",
    String(target.pid),
    "--application",
    target.bundlePath,
    "--input",
    "-",
  ];
}

function closeMessage(status: number | null, signal: NodeJS.Signals | null): string {
  if (signal !== null) {
    return `BrainSurfacer context helper terminated by signal ${signal}`;
  }
  return `BrainSurfacer context helper exited with status ${String(status)}`;
}
