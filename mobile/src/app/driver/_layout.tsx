import { Redirect, Stack } from "expo-router";
import { useAuth } from "../../platform/auth";
import { VARIANT } from "../../platform/config";

export default function DriverLayout() {
  const { status } = useAuth();
  if (VARIANT !== "driver" || status !== "signedIn") return <Redirect href="/" />;
  return <Stack screenOptions={{ headerShown: false }} />;
}
