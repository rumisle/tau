// What a push says, sealed for the phone (docs/notifications.md "Sealed"): AES-256-GCM with the key the app made and
// gave in `devices.register`, so a relay, and Apple, carry ciphertext. The app's notification service extension opens
// it (CryptoKit's AES.GCM.SealedBox(combined:): the 12-byte nonce, the ciphertext, the 16-byte tag).
import { createCipheriv, randomBytes } from "node:crypto";

/** A key as the app gives it: 32 bytes, base64. */
export function isPushKey(value: string): boolean {
	return /^[A-Za-z0-9+/]{43}=$/.test(value) && Buffer.from(value, "base64").length === 32;
}

export function seal(key: string, value: unknown): string {
	const nonce = randomBytes(12);
	const cipher = createCipheriv("aes-256-gcm", Buffer.from(key, "base64"), nonce);
	const text = Buffer.concat([cipher.update(JSON.stringify(value), "utf8"), cipher.final()]);
	return Buffer.concat([nonce, text, cipher.getAuthTag()]).toString("base64");
}
