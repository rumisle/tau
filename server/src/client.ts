// Reference client: what the iOS app does, in TypeScript (../../client), on Node's `ws`. Used by the tests and the CLI.
import WebSocket from "ws";
import { TauClient as Client } from "tau-client/connection";

export { RequestError } from "tau-client/connection";
export { applyOps } from "tau-client/ops";
export type { Entry, Op, Push } from "tau-client/protocol";
export { ConversationReplica } from "tau-client/replica";

export type TauClient = Client;
export const TauClient = {
	/** Connected and greeted, with the token as `Authorization: Bearer`. Images in entries come by reference (media.get). */
	connect(url: string, token?: string): Promise<Client> {
		return Client.open(new WebSocket(url, token === undefined ? {} : { headers: { authorization: `Bearer ${token}` } }));
	},
};
