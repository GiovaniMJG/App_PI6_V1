// Teste de conexão: o ESP32 (no Wokwi) grava um documento no Firestore.
#include <WiFi.h>
#include <WiFiClientSecure.h>
#include <HTTPClient.h>

const char* URL =
    "https://firestore.googleapis.com/v1/projects/estufa-app-pi-6"
    "/databases/(default)/documents/estufa/teste_wokwi";

void setup() {
  Serial.begin(115200);

  // Rede virtual do Wokwi: sem senha, canal 6.
  Serial.print("Conectando ao Wi-Fi");
  WiFi.begin("Wokwi-GUEST", "", 6);
  while (WiFi.status() != WL_CONNECTED) {
    delay(250);
    Serial.print(".");
  }
  Serial.println(" conectado!");

  WiFiClientSecure cliente;
  cliente.setInsecure();  // teste: HTTPS sem verificar o certificado

  HTTPClient http;
  http.begin(cliente, URL);
  http.addHeader("Content-Type", "application/json");
  String corpo =
      "{\"fields\":{"
      "\"mensagem\":{\"stringValue\":\"Ola do ESP32 no Wokwi\"},"
      "\"tempoLigadoMs\":{\"integerValue\":\"" + String(millis()) + "\"}"
      "}}";

  Serial.println("Enviando ao Firestore...");
  int status = http.PATCH(corpo);
  Serial.printf("Resposta do Firestore: %d\n", status);
  Serial.println(http.getString());
  http.end();
}

void loop() {
  delay(1000);
}
