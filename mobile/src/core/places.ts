/** Well-known pickup and drop-off points per city for the taxi screen (the same list as the website); names live in the locale files (fw.place.<city>.<key>). */
export const PLACES: Record<string, { key: string; lat: number; lng: number }[]> = {
  DAM: [
    { key: "marjeh", lat: 33.5113, lng: 36.3007 }, { key: "umayyad", lat: 33.5138, lng: 36.2765 },
    { key: "hamidiyeh", lat: 33.5115, lng: 36.3048 }, { key: "babtouma", lat: 33.5122, lng: 36.3157 },
    { key: "mazzeh", lat: 33.5000, lng: 36.2450 }, { key: "abuRummaneh", lat: 33.5196, lng: 36.2869 },
    { key: "midan", lat: 33.4983, lng: 36.2986 }, { key: "university", lat: 33.5110, lng: 36.2830 },
    { key: "station", lat: 33.5070, lng: 36.2960 }, { key: "jaramana", lat: 33.4855, lng: 36.3460 },
    { key: "airport", lat: 33.4114, lng: 36.5156 },
  ],
  ALP: [
    { key: "citadel", lat: 36.1993, lng: 37.1630 }, { key: "saadallah", lat: 36.2048, lng: 37.1517 },
    { key: "aziziyeh", lat: 36.2120, lng: 37.1480 }, { key: "university", lat: 36.2105, lng: 37.1205 },
    { key: "station", lat: 36.2021, lng: 37.1343 }, { key: "airport", lat: 36.1807, lng: 37.2244 },
  ],
  RDM: [
    { key: "sahnaya", lat: 33.4297, lng: 36.2280 }, { key: "dummar", lat: 33.5420, lng: 36.2230 },
    { key: "qudsaya", lat: 33.5300, lng: 36.2370 }, { key: "harasta", lat: 33.5590, lng: 36.3650 },
  ],
};
