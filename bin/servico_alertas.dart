// Serviço de alertas: acompanha a leitura atual no Firestore e envia o push.
// Usado quando a fonte dos dados é o ESP32 (Wokwi ou placa física), que não
// guarda a chave do Firebase. Rodar sem o simulador (que já envia o próprio push).
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'comum.dart';

// Valor numérico de um campo do Firestore (doubleValue ou integerValue).
double numero(Map<String, dynamic> campo) {
  final valor = campo['doubleValue'] ?? campo['integerValue'];
  return valor is num ? valor.toDouble() : double.parse(valor as String);
}

Future<void> main() async {
  final http.Client? clientePush = await criarClientePush();
  if (clientePush == null) {
    print('Sem a chave do Firebase não há como enviar push. Encerrando.');
    return;
  }
  final monitor = MonitorAlertas();
  String? ultimaLeitura;

  print('Serviço de alertas iniciado (Ctrl+C para parar).');
  while (true) {
    try {
      final resposta = await http.get(leituraAtualUrl);
      if (resposta.statusCode == 200) {
        final campos =
            (jsonDecode(resposta.body) as Map<String, dynamic>)['fields']
                as Map<String, dynamic>;
        final horario =
            (campos['timestamp'] as Map<String, dynamic>?)?['timestampValue']
                as String?;

        // Só avalia leituras novas.
        if (horario != null && horario != ultimaLeitura) {
          ultimaLeitura = horario;
          final double temperatura = numero(
            campos['temperatura'] as Map<String, dynamic>,
          );
          final double umidade = numero(
            campos['umidade'] as Map<String, dynamic>,
          );
          final origem =
              (campos['origem'] as Map<String, dynamic>?)?['stringValue'] ??
              'simulador';
          print(
            'Leitura ($origem): ${temperatura.toStringAsFixed(1)} °C, '
            '${umidade.toStringAsFixed(1)} %',
          );
          final alerta = monitor.avaliar(temperatura, umidade);
          if (alerta != null) {
            await enviarPush(clientePush, alerta.$1, alerta.$2);
          }
        }
      } else {
        print('Erro ao ler o Firestore: ${resposta.statusCode}');
      }
    } catch (erro) {
      print('Falha de conexão, tentando de novo: $erro');
    }
    // Mesmo intervalo das leituras (cerca de 5.760 leituras/dia no Firestore).
    await Future.delayed(const Duration(seconds: 15));
  }
}
