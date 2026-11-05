// Código comum ao simulador (simulador_esp32.dart) e ao serviço de alertas
// (servico_alertas.dart): endereços do Firestore, limites e envio de push.
import 'dart:convert';
import 'dart:io';

import 'package:googleapis_auth/auth_io.dart';
import 'package:http/http.dart' as http;

const String projectId = 'estufa-app-pi-6';
const String basePath =
    'https://firestore.googleapis.com/v1/projects/$projectId'
    '/databases/(default)/documents/estufa/leitura_atual';

// Leitura mais recente (cards do app).
final Uri leituraAtualUrl = Uri.parse(basePath);

// Mesmos limites do app (lib/main.dart).
const double temperaturaMax = 20.0;
const double umidadeMax = 60.0;

// Folga para encerrar um alerta (evita push repetido com o valor oscilando no limite).
const double folgaTemperatura = 0.5;
const double folgaUmidade = 2.0;

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

// Decide quando avisar: uma notificação por saída da faixa, citando tudo o
// que está fora; o alerta só reabre depois de voltar abaixo do limite com folga.
class MonitorAlertas {
  bool _temperatura = false;
  bool _umidade = false;

  // Título e texto da notificação, ou null se não há saída nova da faixa.
  (String, String)? avaliar(double temperatura, double umidade) {
    final bool temperaturaFora = temperatura > temperaturaMax;
    final bool umidadeFora = umidade > umidadeMax;
    final bool novoAlerta =
        (temperaturaFora && !_temperatura) || (umidadeFora && !_umidade);

    if (temperaturaFora) {
      _temperatura = true;
    } else if (temperatura <= temperaturaMax - folgaTemperatura) {
      _temperatura = false;
    }
    if (umidadeFora) {
      _umidade = true;
    } else if (umidade <= umidadeMax - folgaUmidade) {
      _umidade = false;
    }

    if (!novoAlerta) return null;
    final medidas = [
      if (temperaturaFora) 'temperatura',
      if (umidadeFora) 'umidade',
    ];
    final valores = [
      if (temperaturaFora)
        '${temperatura.toStringAsFixed(1)} °C '
            '(limite ${temperaturaMax.toStringAsFixed(0)} °C)',
      if (umidadeFora)
        '${umidade.toStringAsFixed(1)} % '
            '(limite ${umidadeMax.toStringAsFixed(0)} %)',
    ];
    return (
      'Atenção: ${medidas.join(' e ')} fora da faixa segura',
      'Sala de amostras: ${valores.join(' · ')}',
    );
  }
}
