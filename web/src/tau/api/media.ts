// Media for Web A's media loader (`callApi('downloadMedia')`, util/mediaLoader.ts): a kept file over HTTP beside the
// socket, `GET /files/<id>` with the token, or an entry's image with `media.get` (docs/media.md). Web A keeps what it
// loads in the Cache API by its hash, which never changes: files and entries are immutable.
import { ApiMediaFormat } from '../../api/types';

import { serverOrigin } from '../auth';
import { mediaSource } from './attachments';
import { authHeaders, currentClient } from './session';

// Web A's hashes: `photo<id>?size=x`, `document<id>`
const HASH = /^(?:photo|document)([^?]+)/;

export async function downloadMedia(url: string, mediaFormat: ApiMediaFormat) {
  const id = HASH.exec(url)?.[1];
  const source = id ? mediaSource(id) : undefined;
  if (!source || mediaFormat === ApiMediaFormat.Progressive) return undefined;
  let blob: Blob;
  try {
    if ('fileId' in source) {
      const response = await fetch(`${serverOrigin()}/files/${source.fileId}`, { headers: authHeaders() });
      if (!response.ok) return undefined;
      blob = await response.blob();
    } else {
      const client = currentClient();
      if (!client) return undefined;
      const { mimeType, data } = await client.request<{ mimeType: string; data: string }>('media.get', source);
      blob = new Blob([Uint8Array.from(atob(data), (char) => char.charCodeAt(0))], { type: mimeType });
    }
  } catch {
    return undefined;
  }
  if (mediaFormat === ApiMediaFormat.Text) return { dataBlob: await blob.text(), mimeType: blob.type };
  return { dataBlob: blob, mimeType: blob.type, fullSize: blob.size };
}
