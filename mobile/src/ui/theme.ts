// Brand tokens (docs/design/system/tokens.json, identity 1.2): navy for trust, blue for movement, green for arrival.
export const color = {
  navy: "#0B1F3F", primary: "#0A5BD3", primarySoft: "#DCE7FD", green: "#0D7650", greenSoft: "#D3F1E1",
  amber: "#8A5A00", amberSoft: "#FDE7C0", error: "#B3261E", errorSoft: "#F9DEDC",
  surface: "#FFFFFF", background: "#F6F7F9", outline: "#D5DBE3", text: "#0F1B2D", muted: "#4B5565",
  // the logo's own colours: the route, the origin stop and the arrival stop (the trip line, the city boxes)
  route: "#2F7BFF", origin: "#7FB0FF", arrival: "#12A06A",
};
export const radius = { sm: 8, md: 12, lg: 20 };
export const space = (n: number) => n * 4;

// The four families of the identity, one file per weight (assets/fonts, loaded in app/_layout): Readex Pro for titles,
// prices, times and big numbers; IBM Plex Sans Arabic for text and labels; IBM Plex Mono for trip and booking numbers.
// Until the fonts are loaded (or if loading fails) the system font is used.
export const font = {
  display: "ReadexPro-SemiBold", displayBold: "ReadexPro-Bold",
  body: "IBMPlexSansArabic-Regular", medium: "IBMPlexSansArabic-Medium", semibold: "IBMPlexSansArabic-SemiBold",
  mono: "IBMPlexMono-Medium",
};
export const FONT_FILES = {
  "ReadexPro-SemiBold": require("../../assets/fonts/ReadexPro-SemiBold.ttf"),
  "ReadexPro-Bold": require("../../assets/fonts/ReadexPro-Bold.ttf"),
  "IBMPlexSansArabic-Regular": require("../../assets/fonts/IBMPlexSansArabic-Regular.ttf"),
  "IBMPlexSansArabic-Medium": require("../../assets/fonts/IBMPlexSansArabic-Medium.ttf"),
  "IBMPlexSansArabic-SemiBold": require("../../assets/fonts/IBMPlexSansArabic-SemiBold.ttf"),
  "IBMPlexMono-Medium": require("../../assets/fonts/IBMPlexMono-Medium.ttf"),
};
