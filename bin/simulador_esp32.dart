import 'dart:convert';
import 'dart:math';

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

//valor andar de forma aleatória dentro de uma faixa"sensor"
double proximoValor(double atual, double variacaoMax, double min, double max) {
  final delta = (random.nextDouble() * 2 - 1) * variacaoMax;
  double valor = atual + delta;
 
  if (valor < min) valor = min + (min - valor);
  if (valor > max) valor = max - (valor - max);
  valor = valor.clamp(min, max);

  return (valor * 10).round() / 10;// Corrigido de 0.1 arredonda igual.
}

Future<void> main() async {
  double temperatura = 24.5;
  double umidade = 62.0;

  print('Simulador ESP32 iniciado. Ctrl+C para parar.');

  while (true) {
    temperatura = proximoValor(temperatura, 10.0, -30.0, 80.0);
    umidade = proximoValor(umidade, 30.0, 0.0, 100.0);

    final agora = DateTime.now().toUtc().toIso8601String();
    final campos = {
      'temperatura': {'doubleValue': temperatura},
      'umidade': {'doubleValue': umidade},
      'timestamp': {'timestampValue': agora},
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
          'Enviado: temperatura=${temperatura.toStringAsFixed(1)}°C '
          'umidade=${umidade.toStringAsFixed(1)}%',
        );
      } else {
        print(
          'Erro atual=${respostaAtual.statusCode} '
          'historico=${respostaHistorico.statusCode}',
        );
      }
    } catch (erro) {
      print('Falha de conexão, tentando de novo na próxima leitura: $erro');
    }

    await Future.delayed(const Duration(seconds: 5));
  }
}
