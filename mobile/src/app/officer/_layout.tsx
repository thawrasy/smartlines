import { Redirect, Stack } from "expo-router";
import { useAuth } from "../../platform/auth";
import { VARIANT } from "../../platform/config";
import { Loading } from "../../ui/kit";

export default function OfficerLayout() {
  const { status } = useAuth();
  if (VARIANT === "officer" && status === "loading") return <Loading />;
  if (VARIANT !== "officer" || status !== "signedIn") return <Redirect href="/" />;
  return <Stack screenOptions={{ headerShown: false }} />;
}
