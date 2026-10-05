import { Alert, Text, View } from "react-native";
import { useI18n, type Locale } from "../../i18n";
import { useAuth } from "../../platform/auth";
import { Button, Card, Screen, Title, s } from "../../ui/kit";

export default function OperatorAccount() {
  const { t, locale, setLocale } = useI18n();
  const { me, signOut } = useAuth();
  const switchTo = async (l: Locale) => { if (await setLocale(l)) Alert.alert(t("account.restart")); };
  return (
    <Screen>
      <Title sub={me?.email ?? undefined}>{me?.name ?? ""}</Title>
      <Card>
        <Text style={s.h2}>{t("account.language")}</Text>
        <View style={{ gap: 8 }}>
          <Button kind={locale === "en" ? "primary" : "tonal"} label={t("account.english")} onPress={() => switchTo("en")} />
          <Button kind={locale === "ar" ? "primary" : "tonal"} label={t("account.arabic")} onPress={() => switchTo("ar")} />
        </View>
      </Card>
      <Text style={s.small}>{t("op.webHint")}</Text>
      <Button kind="danger" label={t("common.signOut")} onPress={signOut} />
    </Screen>
  );
}
