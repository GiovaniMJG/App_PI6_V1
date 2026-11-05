// Monitor da sala de amostras: ESP32 + DHT22 enviando ao Firestore.
// O mesmo código roda no Wokwi e na placa física; muda só a configuração abaixo.
//
// Dados gravados (mesmo formato do simulador em Dart):
//   estufa/leitura_atual            -> leitura mais recente (cards do app)
//   estufa/leitura_atual/historico  -> uma leitura a cada 15 s (gráficos)
//   estufa/leitura_atual/registros  -> 7h30 e 16h00, com mín./máx. (aba Registros)
// O push é enviado pelo serviço de alertas (bin/servico_alertas.dart), não pelo ESP32.

#include <WiFi.h>
#include <WiFiClientSecure.h>
#include <HTTPClient.h>
#include <time.h>
#include "DHTesp.h"

// ===== Configuração =====
const char* WIFI_NOME = "Wokwi-GUEST";  // na fábrica: nome da rede (2,4 GHz)
const char* WIFI_SENHA = "";            // na fábrica: senha da rede
const int WIFI_CANAL = 6;               // Wokwi usa o canal 6; na fábrica, 0 (procura)
const char* ORIGEM = "wokwi";           // na placa física: "esp32"

// 0: lê o DHT22 (controles deslizantes no Wokwi, sensor real na fábrica).
// 1: gera os dados com o modelo calibrado pela ficha FOR 6.3.3 (sem sensor).
#define MODO_SIMULADO 0

const int PINO_DHT = 15;
const unsigned long INTERVALO_MS = 15000;

// Mesmos limites do app; usados só para mostrar avisos no monitor serial.
const float TEMPERATURA_MAX = 20.0;
const float UMIDADE_MAX = 60.0;

const String BASE =
    "https://firestore.googleapis.com/v1/projects/estufa-app-pi-6"
    "/databases/(default)/documents/estufa/leitura_atual";

// ===== Estruturas =====
struct Leitura {
  float temperatura;
  float umidade;
  bool emDesvio;
  String tipo;
};

DHTesp dht;
WiFiClientSecure cliente;  // conexão HTTPS reaproveitada entre os envios

// ===== Wi-Fi e relógio =====
void conectarWifi() {
  Serial.print("Conectando ao Wi-Fi");
  WiFi.begin(WIFI_NOME, WIFI_SENHA, WIFI_CANAL);
  while (WiFi.status() != WL_CONNECTED) {
    delay(250);
    Serial.print(".");
  }
  Serial.println(" conectado!");
}

void garantirWifi() {
  if (WiFi.status() == WL_CONNECTED) return;
  Serial.println("Wi-Fi caiu, reconectando...");
  WiFi.disconnect();
  conectarWifi();
}

// Horário pela internet (NTP), no fuso de Brasília.
void acertarRelogio() {
  configTzTime("<-03>3", "pool.ntp.org", "time.google.com");
  struct tm t;
  Serial.print("Acertando o relógio");
  while (!getLocalTime(&t, 1000)) Serial.print(".");
  Serial.println(" ok");
}

String horarioUtc(time_t instante) {
  struct tm utc;
  gmtime_r(&instante, &utc);
  char texto[25];
  strftime(texto, sizeof(texto), "%Y-%m-%dT%H:%M:%SZ", &utc);
  return String(texto);
}

String dataLocal(time_t instante) {
  struct tm local;
  localtime_r(&instante, &local);
  char texto[11];
  strftime(texto, sizeof(texto), "%Y-%m-%d", &local);
  return String(texto);
}

// ===== Envio ao Firestore =====
int enviar(const char* metodo, const String& url, const String& corpo) {
  HTTPClient http;
  http.setReuse(true);
  if (!http.begin(cliente, url)) return -1;
  http.addHeader("Content-Type", "application/json");
  int status = strcmp(metodo, "PATCH") == 0 ? http.PATCH(corpo) : http.POST(corpo);
  if (status != 200) {
    Serial.printf("  Erro %d: %s\n", status, http.getString().c_str());
  }
  http.end();
  return status;
}

String campoNumero(const char* nome, float valor) {
  return "\"" + String(nome) + "\":{\"doubleValue\":" + String(valor, 1) + "}";
}

String campoTexto(const char* nome, const String& valor) {
  return "\"" + String(nome) + "\":{\"stringValue\":\"" + valor + "\"}";
}

// ===== Leitura do sensor =====
bool lerSensor(Leitura& leitura) {
  TempAndHumidity valores = dht.getTempAndHumidity();
  if (dht.getStatus() != DHTesp::ERROR_NONE || isnan(valores.temperature) ||
      isnan(valores.humidity)) {
    Serial.printf("Falha na leitura do DHT22: %s\n", dht.getStatusString());
    return false;
  }
  leitura = {valores.temperature, valores.humidity, false, ""};
  return true;
}

// ===== Modo simulado (modelo calibrado, igual ao simulador em Dart) =====
#if MODO_SIMULADO
const float TEMP_MIN_DIA = 17.84, SUBIDA_DIA = 2.25, VAR_TEMP_DIA = 0.78;
const float VAR_SUBIDA_DIA = 1.90, HORA_MAIS_FRIA = 9.90, HORA_PICO = 17.69;
const float RUIDO_TEMP = 0.086, UMID_MAX_DIA = 56.19, QUEDA_UMID = 2.25;
const float VAR_UMID_DIA = 1.50, RUIDO_UMID = 0.382, CHANCE_DESVIO = 0.004;

struct TipoDesvio {
  const char* nome;
  int leituras;
  float passoTemperatura;
  float passoUmidade;
};
const TipoDesvio PORTA_ABERTA = {"portaAberta", 6, 0.5, 2.0};
const TipoDesvio FALHA_REFRIGERACAO = {"falhaRefrigeracao", 20, 0.25, 0.3};
const TipoDesvio PICO_SENSOR = {"picoSensor", 1, 0, 0};
const TipoDesvio UMIDADE_ALTA = {"umidadeAlta", 8, 0, 1.5};  // só pelo monitor serial
const TipoDesvio* SORTEADOS[] = {&PORTA_ABERTA, &FALHA_REFRIGERACAO, &PICO_SENSOR};

struct SorteioDia {
  float base, subida, umidade;
};

float aleatorio() { return esp_random() / 4294967296.0f; }  // [0, 1)
float ruido(float amplitude) { return (aleatorio() * 2 - 1) * amplitude; }
float normal() {
  return sqrtf(-2 * logf(1 - aleatorio())) * cosf(2 * PI * aleatorio());
}
float arredonda(float valor) { return roundf(valor * 10) / 10; }

// 0 na hora mais fria, 1 no pico.
float formaDiaria(float hora) {
  float subida = fmodf(HORA_PICO - HORA_MAIS_FRIA + 24, 24);
  float u = fmodf(hora - HORA_MAIS_FRIA + 24, 24);
  return u < subida ? (1 - cosf(PI * u / subida)) / 2
                    : (1 + cosf(PI * (u - subida) / (24 - subida))) / 2;
}

float tempEstado = NAN, umidEstado = NAN;
float extraTemp = 0, extraUmid = 0;
const TipoDesvio* desvioAtual = nullptr;
const TipoDesvio* desvioPedido = nullptr;
int leiturasRestantes = 0;
int diaAtual = -1;
SorteioDia hoje, amanha;

Leitura simularLeitura(time_t instante) {
  struct tm t;
  localtime_r(&instante, &t);
  if (t.tm_yday != diaAtual) {
    if (diaAtual < 0) {
      hoje = {normal(), normal(), normal()};
    } else {
      hoje = amanha;
    }
    amanha = {normal(), normal(), normal()};
    diaAtual = t.tm_yday;
  }

  // Curva normal do horário, com a variação do dia interpolada.
  float hora = t.tm_hour + t.tm_min / 60.0f + t.tm_sec / 3600.0f;
  float frac = hora / 24;
  auto interpola = [frac](float a, float b) { return a + (b - a) * frac; };
  float forma = formaDiaria(hora);
  float subida =
      fmaxf(0, SUBIDA_DIA + VAR_SUBIDA_DIA * interpola(hoje.subida, amanha.subida)) * forma;
  float alvoTemp = TEMP_MIN_DIA + VAR_TEMP_DIA * interpola(hoje.base, amanha.base) + subida;
  float alvoUmid = UMID_MAX_DIA + VAR_UMID_DIA * interpola(hoje.umidade, amanha.umidade) -
                   QUEDA_UMID * SUBIDA_DIA * forma;

  if (isnan(tempEstado)) {
    tempEstado = alvoTemp;
    umidEstado = alvoUmid;
  }
  tempEstado += (alvoTemp - tempEstado) * 0.1f + ruido(RUIDO_TEMP);
  umidEstado += (alvoUmid - umidEstado) * 0.1f + ruido(RUIDO_UMID);

  // Início de desvio (pedido pelo monitor serial ou sorteio).
  if (desvioAtual == nullptr && fabsf(extraTemp) < 0.3f) {
    if (desvioPedido != nullptr) {
      desvioAtual = desvioPedido;
      desvioPedido = nullptr;
    } else if (aleatorio() < CHANCE_DESVIO) {
      desvioAtual = SORTEADOS[esp_random() % 3];
    }
    leiturasRestantes = desvioAtual != nullptr ? desvioAtual->leituras : 0;
  }

  float pico = 0;
  const TipoDesvio* desvio = desvioAtual;
  if (desvio != nullptr) {
    if (desvio == &PICO_SENSOR) {
      pico = (aleatorio() < 0.5f ? 1 : -1) * (2.5f + aleatorio());
    } else {
      extraTemp += desvio->passoTemperatura;
      extraUmid += desvio->passoUmidade;
    }
    leiturasRestantes--;
  } else {
    extraTemp *= 0.6f;  // retorno gradual ao normal
    extraUmid *= 0.6f;
  }

  bool emDesvio = desvio != nullptr || fabsf(extraTemp) > 0.5f || fabsf(extraUmid) > 2;
  String tipo = desvio != nullptr ? desvio->nome : (emDesvio ? "recuperacao" : "");
  if (leiturasRestantes <= 0) desvioAtual = nullptr;

  return {arredonda(tempEstado + extraTemp + pico),
          arredonda(constrain(umidEstado + extraUmid, 0.0f, 100.0f)), emDesvio, tipo};
}

// Desvio pelo monitor serial: p, f, s ou u.
void lerComandos() {
  while (Serial.available()) {
    switch (tolower(Serial.read())) {
      case 'p': desvioPedido = &PORTA_ABERTA; Serial.println("Pedido: porta aberta"); break;
      case 'f': desvioPedido = &FALHA_REFRIGERACAO; Serial.println("Pedido: falha na refrigeração"); break;
      case 's': desvioPedido = &PICO_SENSOR; Serial.println("Pedido: pico do sensor"); break;
      case 'u': desvioPedido = &UMIDADE_ALTA; Serial.println("Pedido: umidade alta"); break;
    }
  }
}
#endif

// ===== Registros da ficha (7h30 e 16h00) =====
float tempMin = NAN, tempMax = NAN, umidMin = NAN, umidMax = NAN;
time_t proximoRegistro = 0;
const char* periodoRegistro = "";

void acumular(const Leitura& l) {
  tempMin = isnan(tempMin) ? l.temperatura : fminf(tempMin, l.temperatura);
  tempMax = isnan(tempMax) ? l.temperatura : fmaxf(tempMax, l.temperatura);
  umidMin = isnan(umidMin) ? l.umidade : fminf(umidMin, l.umidade);
  umidMax = isnan(umidMax) ? l.umidade : fmaxf(umidMax, l.umidade);
}

void zerarAcumulado() { tempMin = tempMax = umidMin = umidMax = NAN; }

// Próximo horário de registro depois de [depois].
void agendarRegistro(time_t depois) {
  const int horarios[2][2] = {{7, 30}, {16, 0}};
  const char* periodos[2] = {"manha", "tarde"};
  for (int dia = 0; dia < 2; dia++) {
    for (int i = 0; i < 2; i++) {
      struct tm t;
      localtime_r(&depois, &t);
      t.tm_mday += dia;
      t.tm_hour = horarios[i][0];
      t.tm_min = horarios[i][1];
      t.tm_sec = 0;
      t.tm_isdst = -1;
      time_t candidato = mktime(&t);
      if (candidato > depois) {
        proximoRegistro = candidato;
        periodoRegistro = periodos[i];
        return;
      }
    }
  }
}

void gravarRegistro(time_t instante, const Leitura& l) {
  String id = dataLocal(instante) + "_" + periodoRegistro;
  String corpo = "{\"fields\":{" + campoTexto("data", dataLocal(instante)) + "," +
                 campoTexto("periodo", periodoRegistro) + "," +
                 "\"timestamp\":{\"timestampValue\":\"" + horarioUtc(instante) + "\"}," +
                 campoNumero("tempAtual", l.temperatura) + "," +
                 campoNumero("tempMin", tempMin) + "," + campoNumero("tempMax", tempMax) + "," +
                 campoNumero("umidAtual", l.umidade) + "," + campoNumero("umidMin", umidMin) +
                 "," + campoNumero("umidMax", umidMax) + "," + campoTexto("origem", ORIGEM) +
                 "}}";
  if (enviar("PATCH", BASE + "/registros/" + id, corpo) == 200) {
    Serial.printf("  -> Registro da %s gravado.\n", periodoRegistro);
    zerarAcumulado();
    agendarRegistro(instante);
  }
}

// ===== Programa principal =====
void setup() {
  Serial.begin(115200);
  dht.setup(PINO_DHT, DHTesp::DHT22);
  conectarWifi();
  acertarRelogio();
  cliente.setInsecure();  // demonstração; em produção, validar o certificado do Google
  agendarRegistro(time(nullptr));
  Serial.printf("Modo: %s. Origem: %s.\n", MODO_SIMULADO ? "simulado" : "sensor DHT22", ORIGEM);
#if MODO_SIMULADO
  Serial.println("Provocar desvio: p = porta aberta, f = falha, s = pico, u = umidade alta.");
#endif
}

void loop() {
#if MODO_SIMULADO
  lerComandos();
#endif
  static unsigned long ultimoEnvio = 0;
  static bool primeiro = true;
  if (!primeiro && millis() - ultimoEnvio < INTERVALO_MS) return;
  primeiro = false;
  ultimoEnvio = millis();

  garantirWifi();
  time_t agora = time(nullptr);

  Leitura leitura;
#if MODO_SIMULADO
  leitura = simularLeitura(agora);
#else
  if (!lerSensor(leitura)) return;
#endif
  acumular(leitura);

  String campos = "{\"fields\":{" + campoNumero("temperatura", leitura.temperatura) + "," +
                  campoNumero("umidade", leitura.umidade) + "," +
                  "\"timestamp\":{\"timestampValue\":\"" + horarioUtc(agora) + "\"}," +
                  "\"desvioSimulado\":{\"booleanValue\":" +
                  (leitura.emDesvio ? "true" : "false") + "}," +
                  campoTexto("tipoDesvio", leitura.tipo) + "," + campoTexto("origem", ORIGEM) +
                  "}}";

  int atual = enviar("PATCH", BASE, campos);
  int historico = enviar("POST", BASE + "/historico", campos);
  if (atual == 200 && historico == 200) {
    bool fora = leitura.temperatura > TEMPERATURA_MAX || leitura.umidade > UMIDADE_MAX;
    Serial.printf("Enviado: %.1f °C, %.1f %%%s%s\n", leitura.temperatura, leitura.umidade,
                  fora ? "  [fora da faixa]" : "",
                  leitura.emDesvio ? ("  [desvio: " + leitura.tipo + "]").c_str() : "");
  }

  if (agora >= proximoRegistro) gravarRegistro(agora, leitura);
}
