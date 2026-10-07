// Lazy JSON payloads (perf/lazy-payload): a YouTube-ytInitialData-shaped
// ~3 MB payload, parsed (JSON.parse) and compiled (a `var ytInitialData = {…}`
// inline script), then read the way a page's first render reads it (the
// header and the first 24 grid items' titles, thumbnails, bylines).
// Prints parse/compile time, time to first read, live objects and malloc
// bytes after the partial read and after a full read (stringify).
//   jeffjs-cli bench/lazy_json.js                      (lazy, the default)
//   JEFFJS_JSON_LAZY=0 JEFFJS_COMPILE_LAZYLITERALS=0 jeffjs-cli bench/lazy_json.js   (eager)
// __gc / __gcStats / __mallocInUse / __lazyStats are jeffjs-cli natives.
function now() { return Date.now(); }
function stats() { __gc(); __gc(); var g = JSON.parse(__gcStats()); return { objects: g.liveObjects, malloc: +__mallocInUse() }; }
function nav(i, url) {
  return { clickTrackingParams: "CBQQ" + (i * 7919).toString(36) + "ABCDEFGHIJKLMNOP", commandMetadata: { webCommandMetadata: { url: url, webPageType: "WEB_PAGE_TYPE_CHANNEL", rootVe: 3611, apiUrl: "/youtubei/v1/browse" } }, browseEndpoint: { browseId: "UC" + (i * 104729).toString(36) + "xyzXYZ", canonicalBaseUrl: "/@channel" + (i % 97) } };
}
function runs(text, i) { return { runs: [{ text: text, navigationEndpoint: nav(i, "/watch?v=" + i) }], accessibility: { accessibilityData: { label: text + " by Channel " + (i % 97) + " " + (i * 31 % 1000) + "K views" } } }; }
function video(i) {
  var thumbs = [];
  for (var t = 0; t < 4; t++) thumbs.push({ url: "https://i.ytimg.com/vi/v" + i + "/hq" + t + ".jpg?sqp=-oaymwEcCNACELwBSFXyq4qpAw4IARUAAIhCGAFwAcABBg==&rs=AOn4CLC" + i, width: 168 * (t + 1), height: 94 * (t + 1) });
  return { richItemRenderer: { content: { videoRenderer: {
    videoId: "v" + i + "abcdefgh", thumbnail: { thumbnails: thumbs }, title: runs("Video title number " + i + " — café 🎵", i),
    descriptionSnippet: { runs: [{ text: "Description of video " + i + " with some more words to make it realistic in length." }] },
    longBylineText: runs("Channel " + (i % 97), i), publishedTimeText: { simpleText: (i % 11) + " days ago" },
    lengthText: { accessibility: { accessibilityData: { label: (i % 59) + " minutes, " + (i % 60) + " seconds" } }, simpleText: (i % 59) + ":" + (i % 60) },
    viewCountText: { simpleText: (i * 1234 % 1000000) + " views" }, navigationEndpoint: nav(i, "/watch?v=v" + i),
    ownerBadges: [{ metadataBadgeRenderer: { icon: { iconType: "CHECK_CIRCLE_THICK" }, style: "BADGE_STYLE_TYPE_VERIFIED", tooltip: "Verified", trackingParams: "CBkQ" + i } }],
    trackingParams: "CBQQ" + i + "lDyGAAiEwi", showActionMenu: false,
    menu: { menuRenderer: { items: [0, 1, 2].map(function (k) { return { menuServiceItemRenderer: { text: { runs: [{ text: ["Add to queue", "Save to Watch later", "Not interested"][k] }] }, icon: { iconType: ["ADD_TO_QUEUE_TAIL", "WATCH_LATER", "NOT_INTERESTED"][k] }, serviceEndpoint: nav(i * 3 + k, "/service_ajax"), trackingParams: "CBMQ" + k + "_" + i } }; }), trackingParams: "CBMQ" + i, accessibility: { accessibilityData: { label: "Action menu" } } } },
    thumbnailOverlays: [{ thumbnailOverlayTimeStatusRenderer: { text: { simpleText: (i % 59) + ":" + (i % 60) }, style: "DEFAULT" } }, { thumbnailOverlayToggleButtonRenderer: { isToggled: false, untoggledIcon: { iconType: "WATCH_LATER" }, toggledIcon: { iconType: "CHECK" }, untoggledTooltip: "Watch later", toggledTooltip: "Added", trackingParams: "CBYQ" + i } }],
    richThumbnail: { movingThumbnailRenderer: { movingThumbnailDetails: { thumbnails: [{ url: "https://i.ytimg.com/an_webp/v" + i + "/mqdefault_6s.webp", width: 320, height: 180 }], logAsMovingThumbnail: true }, enableHoveredLogging: true, enableOverlay: true } }
  } } } };
}
var contents = [];
for (var i = 0; i < 640; i++) contents.push(video(i));
var data = { responseContext: { serviceTrackingParams: [{ service: "GFEEDBACK", params: [{ key: "route", value: "channel." }, { key: "is_casual", value: "false" }] }], maxAgeSeconds: 300, mainAppWebResponseContext: { loggedOut: true, trackingParam: "kx_fmPxhoPZR" } },
  contents: { twoColumnBrowseResultsRenderer: { tabs: [{ tabRenderer: { selected: true, content: { richGridRenderer: { contents: contents, header: { feedFilterChipBarRenderer: { contents: [] } }, trackingParams: "CAAQ" } }, title: "Home" } }] } },
  header: { c4TabbedHeaderRenderer: { channelId: "UCabc", title: "Bench Channel", badges: [], subscriberCountText: { simpleText: "1.2M subscribers" } } },
  topbar: { desktopTopbarRenderer: { logo: { topbarLogoRenderer: { iconImage: { iconType: "YOUTUBE_LOGO" }, tooltipText: { runs: [{ text: "YouTube Home" }] } } } } } };
var text = JSON.stringify(data);
data = null; contents = null;

function firstRender(d) {
  // What a first paint reads: header + the first 24 grid items.
  var out = [d.header.c4TabbedHeaderRenderer.title, d.header.c4TabbedHeaderRenderer.subscriberCountText.simpleText];
  var grid = d.contents.twoColumnBrowseResultsRenderer.tabs[0].tabRenderer.content.richGridRenderer.contents;
  for (var i = 0; i < 24; i++) {
    var v = grid[i].richItemRenderer.content.videoRenderer;
    out.push(v.videoId, v.title.runs[0].text, v.thumbnail.thumbnails[0].url, v.longBylineText.runs[0].text, v.viewCountText.simpleText, v.lengthText.simpleText);
  }
  return out.join("|").length + grid.length;
}

function report(label, t0, t1, t2, base) {
  var s = stats();
  console.log(label + "\tparse_ms\t" + (t1 - t0) + "\tfirst_read_ms\t" + (t2 - t1) + "\tobjects\t" + (s.objects - base.objects) + "\tmalloc_MB\t" + ((s.malloc - base.malloc) / 1048576).toFixed(2));
}

console.log("text_bytes\t" + text.length);
// 1. JSON.parse
var base = stats();
var t0 = now();
var y = JSON.parse(text);
var t1 = now();
var r = firstRender(y);
var t2 = now();
report("json_partial", t0, t1, t2, base);
var t3 = now(); var s2 = JSON.stringify(y); var t4 = now();
var full = stats();
console.log("json_full\tstringify_ms\t" + (t4 - t3) + "\tobjects\t" + (full.objects - base.objects) + "\tmalloc_MB\t" + ((full.malloc - base.malloc) / 1048576).toFixed(2) + "\tsame\t" + (s2 === text));
s2 = null;
// Memory pressure: pristine objects revert to their spans (lazy only).
if (typeof __lazyEvict === "function") {
  var te = now(); var nEv = +__lazyEvict(); var te2 = now();
  var ev = stats();
  var tr = now(); firstRender(y); var tr2 = now();
  console.log("json_evicted\tevict_ms\t" + (te2 - te) + "\treverted\t" + nEv + "\tobjects\t" + (ev.objects - base.objects) + "\tmalloc_MB\t" + ((ev.malloc - base.malloc) / 1048576).toFixed(2) + "\treread_ms\t" + (tr2 - tr));
}
y = null;
// 2. Inline-script literal (`var ytInitialData = {…}`), through indirect eval.
base = stats();
t0 = now();
(0, eval)("var ytInitialData = " + text + ";");
t1 = now();
r = firstRender(ytInitialData);
t2 = now();
report("literal_partial", t0, t1, t2, base);
ytInitialData = null;
if (typeof __lazyStats === "function") console.log("lazy\t" + __lazyStats());
