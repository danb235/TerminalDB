export interface WebSocketCostInput {
  readonly activeHours: number;
  readonly batchesPerSecond: number;
  readonly controllers?: number;
  readonly averageWireBytes?: number;
}

export interface WebSocketCostEstimate {
  readonly inboundMessages: number;
  readonly outboundMessages: number;
  readonly billableMessages: number;
  readonly messageCostUsd: number;
  readonly transferGb: number;
}

const MESSAGE_CHUNK_BYTES = 32 * 1024;

export function estimateWebSocketCost(
  input: WebSocketCostInput,
): WebSocketCostEstimate {
  const controllers = input.controllers ?? 1;
  const wireBytes = input.averageWireBytes ?? 12 * 1024;
  const batches =
    input.activeHours * 60 * 60 * input.batchesPerSecond;
  const chunks = Math.max(1, Math.ceil(wireBytes / MESSAGE_CHUNK_BYTES));
  const inboundMessages = Math.ceil(batches * chunks);
  const outboundMessages = Math.ceil(batches * chunks * controllers);
  const billableMessages = inboundMessages + outboundMessages;
  return {
    inboundMessages,
    outboundMessages,
    billableMessages,
    messageCostUsd: billableMessages / 1_000_000,
    transferGb:
      (batches * wireBytes * controllers) / (1024 * 1024 * 1024),
  };
}
