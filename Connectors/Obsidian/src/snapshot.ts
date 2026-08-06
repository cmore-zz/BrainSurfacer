export const maximumDocumentCount = 100;
export const maximumPathBytes = 16_384;
export const minimumTimeToLive = 1;
export const maximumTimeToLive = 300;

export interface WorkspaceDocument {
  path: string;
  selected: boolean;
  visible: boolean;
}

export interface ContextSnapshot {
  selected: string[];
  visible: string[];
  open: string[];
}

interface RankedDocument {
  path: string;
  relevance: Relevance;
}

enum Relevance {
  open = 1,
  visible = 2,
  selected = 3,
}

const textEncoder = new TextEncoder();

export function normalizedTimeToLive(value: number): number {
  if (!Number.isFinite(value)) {
    return 60;
  }
  return Math.max(
    minimumTimeToLive,
    Math.min(maximumTimeToLive, Math.trunc(value)),
  );
}

export function buildSnapshot(documents: WorkspaceDocument[]): ContextSnapshot {
  const relevanceByPath = new Map<string, Relevance>();
  for (const document of documents) {
    if (document.path.length === 0) {
      continue;
    }
    const relevance = document.selected
      ? Relevance.selected
      : document.visible
        ? Relevance.visible
        : Relevance.open;
    const previous = relevanceByPath.get(document.path) ?? Relevance.open;
    relevanceByPath.set(document.path, Math.max(previous, relevance));
  }

  const ranked: RankedDocument[] = Array.from(
    relevanceByPath,
    ([path, relevance]) => ({ path, relevance }),
  ).sort((left, right) => {
    const relevanceOrder = right.relevance - left.relevance;
    return relevanceOrder === 0 ? comparePaths(left.path, right.path) : relevanceOrder;
  });

  const snapshot: ContextSnapshot = { selected: [], visible: [], open: [] };
  let pathBytes = 0;
  for (const document of ranked) {
    if (
      snapshot.selected.length + snapshot.visible.length + snapshot.open.length
        >= maximumDocumentCount
    ) {
      break;
    }
    const bytes = textEncoder.encode(document.path).byteLength;
    if (pathBytes + bytes > maximumPathBytes) {
      // Stop at the byte budget rather than skipping ahead: `ranked` is in
      // descending relevance order, so breaking keeps the highest-relevance
      // prefix instead of dropping a long selected/visible path in favor of
      // shorter, lower-relevance ones that happen to fit.
      break;
    }
    pathBytes += bytes;
    switch (document.relevance) {
      case Relevance.selected:
        snapshot.selected.push(document.path);
        break;
      case Relevance.visible:
        snapshot.visible.push(document.path);
        break;
      case Relevance.open:
        snapshot.open.push(document.path);
        break;
    }
  }
  return snapshot;
}

export function encodePayload(
  providerID: string,
  timeToLive: number,
  snapshot: ContextSnapshot,
): string {
  return JSON.stringify({
    providerID,
    timeToLive: normalizedTimeToLive(timeToLive),
    selected: snapshot.selected,
    visible: snapshot.visible,
    open: snapshot.open,
  });
}

function comparePaths(left: string, right: string): number {
  if (left < right) {
    return -1;
  }
  return left > right ? 1 : 0;
}
