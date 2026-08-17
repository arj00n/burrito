import { getSelectedFinderItems, open, showHUD } from "@raycast/api";

export type Format = "png" | "webp" | "pdf" | "webm" | "mp4";

export async function convert(format: Format) {
  try {
    const items = await getSelectedFinderItems();
    if (items.length === 0) {
      await showHUD("Select files in Finder first");
      return;
    }

    const files = items.map((item) => `file=${encodeURIComponent(item.path)}`).join("&");
    await open(`burrito://convert/${format}?${files}`);
    await showHUD(`Burrito is processing ${items.length} ${items.length === 1 ? "file" : "files"}…`);
  } catch {
    await showHUD("Select files in Finder and make sure Burrito is installed");
  }
}
