import { base64UrlEncode, exportPublicKey, generateIdentityKeyPair, utf8 } from "@terminaldb/protocol";

const DATABASE = "terminaldb-remote";
const STORE = "keys";
const IDENTITY_KEY = "controller-identity-v1";
const SESSION_KEY = "controller-session-v1";
const BROWSER_ID_KEY = "account-browser-id-v1";

function arrayBuffer(bytes: Uint8Array): ArrayBuffer {
  const copy = new Uint8Array(bytes.byteLength);
  copy.set(bytes);
  return copy.buffer;
}

export interface ControllerIdentity {
  readonly signingPrivateKey: CryptoKey;
  readonly signingPublicKey: JsonWebKey;
  readonly agreementPrivateKey: CryptoKey;
  readonly agreementPublicKey: JsonWebKey;
}

export interface StoredControllerSession {
  readonly controllerId: string;
  readonly sessionId: string;
  readonly generation: number;
  readonly sendKey: CryptoKey;
  readonly receiveKey: CryptoKey;
  readonly accessMode?: "pairing" | "account";
}

function openDatabase(): Promise<IDBDatabase> {
  return new Promise((resolve, reject) => {
    const request = indexedDB.open(DATABASE, 1);
    request.onupgradeneeded = () => {
      request.result.createObjectStore(STORE);
    };
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
}

async function getRecord<T>(key: string): Promise<T | undefined> {
  const database = await openDatabase();
  return new Promise((resolve, reject) => {
    const transaction = database.transaction(STORE, "readonly");
    const request = transaction.objectStore(STORE).get(key);
    request.onsuccess = () => resolve(request.result as T | undefined);
    request.onerror = () => reject(request.error);
    transaction.oncomplete = () => database.close();
  });
}

async function putRecord(key: string, value: unknown): Promise<void> {
  const database = await openDatabase();
  return new Promise((resolve, reject) => {
    const transaction = database.transaction(STORE, "readwrite");
    transaction.objectStore(STORE).put(value, key);
    transaction.oncomplete = () => {
      database.close();
      resolve();
    };
    transaction.onerror = () => reject(transaction.error);
  });
}

export async function loadOrCreateIdentity(): Promise<ControllerIdentity> {
  const stored = await getRecord<ControllerIdentity>(IDENTITY_KEY);
  if (stored) return stored;
  const signing = await crypto.subtle.generateKey(
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign", "verify"],
  );
  const agreement = await generateIdentityKeyPair();
  const identity: ControllerIdentity = {
    signingPrivateKey: signing.privateKey,
    signingPublicKey: await crypto.subtle.exportKey("jwk", signing.publicKey),
    agreementPrivateKey: agreement.privateKey,
    agreementPublicKey: await exportPublicKey(agreement.publicKey),
  };
  await putRecord(IDENTITY_KEY, identity);
  return identity;
}

export async function loadOrCreateBrowserId(): Promise<string> {
  const stored = await getRecord<string>(BROWSER_ID_KEY);
  if (stored) return stored;
  const browserId = crypto.randomUUID();
  await putRecord(BROWSER_ID_KEY, browserId);
  return browserId;
}

export async function saveControllerSession(
  session: StoredControllerSession,
): Promise<void> {
  await putRecord(SESSION_KEY, session);
}

export async function loadControllerSession(): Promise<StoredControllerSession | undefined> {
  return getRecord<StoredControllerSession>(SESSION_KEY);
}

export async function clearControllerSession(): Promise<void> {
  const database = await openDatabase();
  await new Promise<void>((resolve, reject) => {
    const transaction = database.transaction(STORE, "readwrite");
    transaction.objectStore(STORE).delete(SESSION_KEY);
    transaction.oncomplete = () => {
      database.close();
      resolve();
    };
    transaction.onerror = () => reject(transaction.error);
  });
}

async function sha256(value: string): Promise<string> {
  const hash = await crypto.subtle.digest("SHA-256", arrayBuffer(utf8(value)));
  return base64UrlEncode(new Uint8Array(hash));
}

export async function authenticatedHeaders(input: {
  readonly method: string;
  readonly path: string;
  readonly body: string;
  readonly principalId: string;
  readonly privateKey: CryptoKey;
}): Promise<Record<string, string>> {
  const timestamp = Date.now().toString();
  const nonce = crypto.randomUUID();
  const canonical = [
    input.method.toUpperCase(),
    input.path,
    timestamp,
    nonce,
    await sha256(input.body),
  ].join("\n");
  const signature = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    input.privateKey,
    arrayBuffer(utf8(canonical)),
  );
  return {
    "content-type": "application/json",
    "x-terminaldb-principal": input.principalId,
    "x-terminaldb-timestamp": timestamp,
    "x-terminaldb-nonce": nonce,
    "x-terminaldb-signature": base64UrlEncode(new Uint8Array(signature)),
  };
}
