import { Redirect } from "expo-router";
import { useAuth } from "../platform/auth";
import { VARIANT } from "../platform/config";
import { Loading } from "../ui/kit";

export default function Index() {
  const { status } = useAuth();
  if (status === "loading") return <Loading />;
  if (status === "signedOut") return <Redirect href="/login" />;
  if (status === "mfa") return <Redirect href="/mfa" />;
  return <Redirect href={VARIANT === "driver" ? "/driver" : VARIANT === "operator" ? "/operator" : "/book"} />;
}
