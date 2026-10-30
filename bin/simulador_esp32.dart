import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:googleapis_auth/auth_io.dart';
import 'package:http/http.dart' as http;

// Simula ESP32 enviando leituras de temperatura/umidade pro Firestore, REST API
const String projectId = 'estufa-app-pi-6';
const String basePath =
    'https://firestore.googleapis.com/v1/projects/$projectId'
    '/databases/(default)/documents/estufa/leitura_atual';

// leitura mais recente  (cards)
final Uri leituraAtualUrl = Uri.parse(basePath);

final Uri historicoUrl = Uri.parse('$basePath/historico');

final Random random = Random();

// Mesmos limites do app (lib/main.dart).
const double temperaturaMax = 20.0;
const double umidadeMax = 60.0;

// Chave da conta de serviço (push), mantida fora do repositório.
const String caminhoChave = '../chave-firebase.json';
final Uri envioPushUrl = Uri.parse(
  'https://fcm.googleapis.com/v1/projects/$projectId/messages:send',
);

// Cliente autenticado para o FCM; null sem a chave.
Future<http.Client?> criarClientePush() async {
  final arquivo = File(caminhoChave);
  if (!arquivo.existsSync()) {
    print(
      'Aviso: $caminhoChave não encontrado. Notificações push desativadas.',
    );
    return null;
  }
  final credenciais = ServiceAccountCredentials.fromJson(
    jsonDecode(arquivo.readAsStringSync()),
  );
  return clientViaServiceAccount(credenciais, [
    'https://www.googleapis.com/auth/firebase.messaging',
  ]);
}

// Envia notificação ao tópico "alertas".
Future<void> enviarPush(
  http.Client cliente,
  String titulo,
  String texto,
) async {
  try {
    final resposta = await cliente.post(
      envioPushUrl,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'message': {
          'topic': 'alertas',
          'notification': {'title': titulo, 'body': texto},
          'android': {'priority': 'high'},
        },
      }),
    );
    print(
      resposta.statusCode == 200
          ? '  -> Notificação enviada: $texto'
          : '  -> Falha ao enviar notificação (${resposta.statusCode}): ${resposta.body}',
    );
  } catch (erro) {
    print('  -> Falha ao enviar notificação: $erro');
  }
}

// Condição normal da sala.
const double temperaturaBase = 18.0;
const double umidadeBase = 52.0;

// Probabilidade de desvio por leitura (~1 a cada 12 min).
const double chanceDesvio = 0.02;

// Desvios simulados; leituras afetadas são marcadas (desvioSimulado),
// servindo de gabarito para avaliar o modelo de ML.
enum TipoDesvio {
  portaAberta(leituras: 6, passoTemperatura: 0.5, passoUmidade: 2.0),
  falhaRefrigeracao(leituras: 20, passoTemperatura: 0.25, passoUmidade: 0.3),
  picoSensor(leituras: 1, passoTemperatura: 0, passoUmidade: 0);

  final int leituras;
  final double passoTemperatura;
  final double passoUmidade;
  const TipoDesvio({
    required this.leituras,
    required this.passoTemperatura,
    required this.passoUmidade,
  });
}

double arredonda(double valor) =>
    (valor * 10).round() / 10; // resolução do DHT22

// Valor aleatório em [-amplitude, +amplitude].
double ruido(double amplitude) => (random.nextDouble() * 2 - 1) * amplitude;

Future<void> main() async {
  final http.Client? clientePush = await criarClientePush();

  // Push só na transição para fora da faixa.
  bool temperaturaForaAntes = false;
  bool umidadeForaAntes = false;

  double temperatura = temperaturaBase;
  double umidade = umidadeBase;

  // Acréscimo do desvio em andamento.
  double extraTemperatura = 0;
  double extraUmidade = 0;

  TipoDesvio? desvioAtual;
  int leiturasRestantes = 0;
  TipoDesvio? desvioPedido; // escolhido pelo teclado

  // Desvio manual pelo teclado: p, f ou s + Enter.
  stdin.transform(utf8.decoder).transform(const LineSplitter()).listen((linha) {
    desvioPedido = switch (linha.trim().toLowerCase()) {
      'p' => TipoDesvio.portaAberta,
      'f' => TipoDesvio.falhaRefrigeracao,
      's' => TipoDesvio.picoSensor,
      _ => null,
    };
  });

  print('Simulador ESP32 iniciado. Ctrl+C para parar.');
  print(
    'Provocar desvio: p = porta aberta, f = falha na refrigeração, '
    's = pico do sensor (digite e aperte Enter).',
  );

  while (true) {
    // Oscilação normal, com retorno ao valor base.
    temperatura += (temperaturaBase - temperatura) * 0.1 + ruido(0.2);
    umidade += (umidadeBase - umidade) * 0.1 + ruido(0.8);

    // Início de desvio (teclado ou sorteio).
    if (desvioAtual == null && extraTemperatura.abs() < 0.3) {
      if (desvioPedido != null) {
        desvioAtual = desvioPedido;
        desvioPedido = null;
      } else if (random.nextDouble() < chanceDesvio) {
        desvioAtual =
            TipoDesvio.values[random.nextInt(TipoDesvio.values.length)];
      }
      leiturasRestantes = desvioAtual?.leituras ?? 0;
    }

    // Efeito do desvio.
    double pico = 0;
    if (desvioAtual != null) {
      if (desvioAtual == TipoDesvio.picoSensor) {
        // Leitura isolada errada; para baixo fica dentro da faixa.
        pico = (random.nextBool() ? 1 : -1) * (2.5 + random.nextDouble());
      } else {
        extraTemperatura += desvioAtual.passoTemperatura;
        extraUmidade += desvioAtual.passoUmidade;
      }
      leiturasRestantes--;
    } else {
      // Retorno gradual ao normal.
      extraTemperatura *= 0.6;
      extraUmidade *= 0.6;
    }

    final bool emDesvio =
        desvioAtual != null ||
        extraTemperatura.abs() > 0.5 ||
        extraUmidade.abs() > 2;
    final String tipo = desvioAtual?.name ?? (emDesvio ? 'recuperacao' : '');

    final double temperaturaLida = arredonda(
      (temperatura + extraTemperatura + pico).clamp(-40.0, 80.0),
    );
    final double umidadeLida = arredonda(
      (umidade + extraUmidade).clamp(0.0, 100.0),
    );

    if (leiturasRestantes <= 0) desvioAtual = null;

    final agora = DateTime.now().toUtc().toIso8601String();
    final campos = {
      'temperatura': {'doubleValue': temperaturaLida},
      'umidade': {'doubleValue': umidadeLida},
      'timestamp': {'timestampValue': agora},
      'desvioSimulado': {'booleanValue': emDesvio},
      'tipoDesvio': {'stringValue': tipo},
    };

    try {
      final respostaAtual = await http.patch(
        leituraAtualUrl,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'fields': campos}),
      );

      final respostaHistorico = await http.post(
        historicoUrl,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'fields': campos}),
      );

      if (respostaAtual.statusCode == 200 &&
          respostaHistorico.statusCode == 200) {
        print(
          'Enviado: temperatura=${temperaturaLida.toStringAsFixed(1)}°C '
          'umidade=${umidadeLida.toStringAsFixed(1)}%'
          '${emDesvio ? '  [desvio: $tipo]' : ''}',
        );

        final bool temperaturaFora = temperaturaLida > temperaturaMax;
        final bool umidadeFora = umidadeLida > umidadeMax;
        if (clientePush != null) {
          if (temperaturaFora && !temperaturaForaAntes) {
            await enviarPush(
              clientePush,
              'Temperatura acima do limite',
              'Sala de amostras: ${temperaturaLida.toStringAsFixed(1)} °C '
                  '(limite ${temperaturaMax.toStringAsFixed(0)} °C)',
            );
          }
          if (umidadeFora && !umidadeForaAntes) {
            await enviarPush(
              clientePush,
              'Umidade acima do limite',
              'Sala de amostras: ${umidadeLida.toStringAsFixed(1)} % '
                  '(limite ${umidadeMax.toStringAsFixed(0)} %)',
            );
          }
        }
        temperaturaForaAntes = temperaturaFora;
        umidadeForaAntes = umidadeFora;
      } else {
        print(
          'Erro atual=${respostaAtual.statusCode} '
          'historico=${respostaHistorico.statusCode}',
        );
      }
    } catch (erro) {
      print('Falha de conexão, tentando de novo na próxima leitura: $erro');
    }

    // 15 s: 11.520 gravações/dia, abaixo da cota gratuita (20.000).
    await Future.delayed(const Duration(seconds: 15));
  }
}
