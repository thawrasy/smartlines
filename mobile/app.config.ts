// One code base, three apps. Build with APP_VARIANT=passenger (default), APP_VARIANT=driver or APP_VARIANT=operator.
//   MASSLAK_API_URL   https base address of the API, e.g. https://masslak.com
//   MASSLAK_API_PINS  comma-separated base64 SHA-256 hashes of the API certificate's public key (at least two:
//                     the current key and a backup), enforced by native certificate pinning in release builds
import type { ConfigContext, ExpoConfig } from "expo/config";

const VARIANTS = {
  passenger: { name: "Masslak", slug: "masslak", id: "sy.masslak.app" },
  driver: { name: "Masslak Driver", slug: "masslak-driver", id: "sy.masslak.driver" },
  operator: { name: "Masslak Business", slug: "masslak-business", id: "sy.masslak.business" },
} as const;

export default ({ config }: ConfigContext): ExpoConfig => {
  const wanted = process.env.APP_VARIANT;
  const variant = (wanted === "driver" || wanted === "operator" ? wanted : "passenger") as keyof typeof VARIANTS;
  const v = VARIANTS[variant];
  const apiUrl = process.env.MASSLAK_API_URL ?? "https://masslak.com";
  if (!apiUrl.startsWith("https://") && process.env.NODE_ENV === "production") {
    throw new Error("MASSLAK_API_URL must use https in release builds");
  }
  return {
    ...config,
    name: v.name,
    slug: v.slug,
    scheme: v.slug,
    version: "1.0.0",
    orientation: "portrait",
    icon: "./assets/icon.png",
    userInterfaceStyle: "light",
    ios: {
      bundleIdentifier: v.id,
      supportsTablet: false,
      infoPlist: {
        NSCameraUsageDescription: variant === "driver"
          ? "The camera scans passengers' ticket codes when they board."
          : variant === "operator" ? "The camera scans ticket and parcel codes."
          : "The camera scans the code inside the vehicle when you ride a shuttle.",
        NSFaceIDUsageDescription: "Face ID unlocks your tickets and wallet.",
        ITSAppUsesNonExemptEncryption: false,
      },
    },
    android: {
      package: v.id,
      adaptiveIcon: {
        backgroundColor: "#0B1F3F",
        foregroundImage: "./assets/android-icon-foreground.png",
        backgroundImage: "./assets/android-icon-background.png",
        monochromeImage: "./assets/android-icon-monochrome.png",
      },
      permissions: ["android.permission.CAMERA", "android.permission.USE_BIOMETRIC"],
      blockedPermissions: ["android.permission.RECORD_AUDIO"],
      allowBackup: false, // tokens and offline tickets never leave the device in a cloud backup
    },
    plugins: [
      "expo-router",
      "expo-secure-store",
      ["expo-camera", { recordAudioAndroid: false }],
      ["expo-local-authentication", { faceIDPermission: "Face ID unlocks your tickets and wallet." }],
      "expo-localization",
    ],
    experiments: { typedRoutes: false },
    extra: {
      variant,
      apiUrl,
      apiPins: (process.env.MASSLAK_API_PINS ?? "").split(",").map((s: string) => s.trim()).filter(Boolean),
    },
  };
};
