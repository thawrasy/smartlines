import { Redirect, Stack } from "expo-router";
import { useAuth } from "../../platform/auth";
import { VARIANT } from "../../platform/config";
import { Loading } from "../../ui/kit";

export default function DriverLayout() {
  const { status } = useAuth();
  if (VARIANT === "driver" && status === "loading") return <Loading />;   // keep the deep link while the session loads
  if (VARIANT !== "driver" || status !== "signedIn") return <Redirect href="/" />;
  return <Stack screenOptions={{ headerShown: false }} />;
}
