"""Detecção de anomalias nas leituras de temperatura e umidade (Isolation Forest).

Uso:
    python ml/detectar_anomalias.py                # CSV principal (ml/dados_simulados.csv)
    python ml/detectar_anomalias.py --repeticoes   # também avalia ml/repeticoes/*.csv
    python ml/detectar_anomalias.py --firebase     # também aplica ao histórico do Firestore

Dados (simulador calibrado com a ficha FOR 6.3.3, ver ml/calibrar_simulador.py):
    dart run bin/simulador_esp32.dart --csv 40320                  # 7 dias, semente 1
    dart run bin/simulador_esp32.dart --csv 40320 --repeticoes 10  # sementes 1 a 10
"""

import argparse
import json
import urllib.request
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.dates as mdates
import matplotlib.pyplot as plt
import numpy as np
import pandas as pd
from sklearn.ensemble import IsolationForest
from sklearn.metrics import confusion_matrix, f1_score, precision_score, recall_score

PASTA = Path(__file__).parent
CSV_PADRAO = PASTA / "dados_simulados.csv"
PASTA_REPETICOES = PASTA / "repeticoes"

# Mesmos limites do app (lib/main.dart).
TEMPERATURA_MAX = 20.0
UMIDADE_MAX = 60.0

# Divisão temporal: treino, validação (escolha do modelo) e teste (avaliação final).
PROPORCAO_TREINO = 0.6
PROPORCAO_VALIDACAO = 0.2

JANELA_MEDIA = 40  # leituras (10 min com 1 leitura a cada 15 s)
MINUTOS_FAIXA = 30  # resolução do perfil diário
ARVORES = 200
SEMENTE = 42
CONTAMINACOES = [0.01, 0.02, 0.03, 0.04, 0.05, 0.06, 0.08, 0.10, 0.15]

VARIACOES = [
    "variacao_temperatura",
    "variacao_umidade",
    "desvio_media_temperatura",
    "desvio_media_umidade",
]
CONJUNTOS = {
    "valores lidos": ["temperatura", "umidade"] + VARIACOES,
    "perfil diário": ["desvio_perfil_temperatura", "desvio_perfil_umidade"] + VARIACOES,
}

FUSO = "America/Sao_Paulo"

FIRESTORE_HISTORICO = (
    "https://firestore.googleapis.com/v1/projects/estufa-app-pi-6/databases/"
    "(default)/documents/estufa/leitura_atual/historico"
)


def ler_csv(caminho: Path) -> pd.DataFrame:
    df = pd.read_csv(caminho, keep_default_na=False)
    df["timestamp"] = pd.to_datetime(df["timestamp"], format="ISO8601", utc=True)
    return df


def calcular_entradas(df: pd.DataFrame) -> pd.DataFrame:
    """Variação em relação à leitura anterior, distância da mediana dos últimos
    10 min e faixa de horário (para o perfil diário). Só usa leituras passadas."""
    df = df.sort_values("timestamp").reset_index(drop=True)
    for campo in ("temperatura", "umidade"):
        df[f"variacao_{campo}"] = df[campo].diff().fillna(0)
        mediana = df[campo].rolling(JANELA_MEDIA, min_periods=1).median()
        df[f"desvio_media_{campo}"] = df[campo] - mediana
    local = df["timestamp"].dt.tz_convert(FUSO)
    df["faixa"] = (local.dt.hour * 60 + local.dt.minute) // MINUTOS_FAIXA
    return df


def perfil_diario(treino: pd.DataFrame) -> pd.DataFrame:
    """Valor típico de cada faixa de horário, aprendido no treino (mediana)."""
    return treino.groupby("faixa")[["temperatura", "umidade"]].median()


def aplicar_perfil(df: pd.DataFrame, perfil: pd.DataFrame) -> pd.DataFrame:
    df = df.copy()
    for campo in ("temperatura", "umidade"):
        df[f"desvio_perfil_{campo}"] = df[campo] - df["faixa"].map(perfil[campo])
    return df


def metricas(real, previsto) -> dict:
    return {
        "precisao": precision_score(real, previsto, zero_division=0),
        "recall": recall_score(real, previsto, zero_division=0),
        "f1": f1_score(real, previsto, zero_division=0),
    }


class Detector:
    """Isolation Forest treinado sem rótulos; o limiar de anomalia é o
    percentil das pontuações do treino dado pela contaminação."""

    def __init__(self, colunas, treino):
        self.colunas = colunas
        self.modelo = IsolationForest(n_estimators=ARVORES, random_state=SEMENTE)
        self.modelo.fit(treino[colunas])
        self.pontos_treino = self.modelo.score_samples(treino[colunas])
        self.limiar = None

    def definir_contaminacao(self, contaminacao):
        self.contaminacao = contaminacao
        self.limiar = np.percentile(self.pontos_treino, 100 * contaminacao)

    def prever(self, df, limiar=None):
        limiar = self.limiar if limiar is None else limiar
        return (self.modelo.score_samples(df[self.colunas]) < limiar).astype(int)


def avaliar(caminho: Path) -> dict:
    df = calcular_entradas(ler_csv(caminho))
    n = len(df)
    fim_treino = int(n * PROPORCAO_TREINO)
    fim_validacao = int(n * (PROPORCAO_TREINO + PROPORCAO_VALIDACAO))
    treino = df.iloc[:fim_treino]
    perfil = perfil_diario(treino)
    df = aplicar_perfil(df, perfil)
    treino = df.iloc[:fim_treino]
    validacao = df.iloc[fim_treino:fim_validacao]
    teste = df.iloc[fim_validacao:].copy()

    # Validação: escolhe conjunto de entradas e contaminação pelo F1 (rótulos só aqui e no teste).
    detectores, tabela_validacao = {}, {}
    for nome, colunas in CONJUNTOS.items():
        detector = Detector(colunas, treino)
        pontos_val = detector.modelo.score_samples(validacao[colunas])
        f1s = []
        for c in CONTAMINACOES:
            previsto = (pontos_val < np.percentile(detector.pontos_treino, 100 * c)).astype(int)
            f1s.append(metricas(validacao["desvioSimulado"], previsto)["f1"])
        detector.definir_contaminacao(CONTAMINACOES[int(np.argmax(f1s))])
        detectores[nome] = detector
        tabela_validacao[nome] = f1s
    escolhido = max(tabela_validacao, key=lambda k: max(tabela_validacao[k]))

    # Teste: avaliação final, uma vez, com o que foi escolhido na validação.
    real = teste["desvioSimulado"]
    dias_teste = (teste["timestamp"].iloc[-1] - teste["timestamp"].iloc[0]).total_seconds() / 86400
    resultados = {}
    for nome, detector in detectores.items():
        teste[f"anomalia_{nome}"] = detector.prever(teste)
    teste["anomalia_limite"] = (
        (teste["temperatura"] > TEMPERATURA_MAX) | (teste["umidade"] > UMIDADE_MAX)
    ).astype(int)
    for coluna in [f"anomalia_{n}" for n in CONJUNTOS] + ["anomalia_limite"]:
        m = metricas(real, teste[coluna])
        # Tempo em alarme falso: leituras de 15 s marcadas sem desvio, em minutos por dia
        m["falsos_por_dia"] = int(((teste[coluna] == 1) & (real == 0)).sum()) * 15 / 60 / dias_teste
        resultados[coluna] = m
    teste["anomalia_modelo"] = teste[f"anomalia_{escolhido}"]

    por_tipo = (teste[teste["desvioSimulado"] == 1]
                .groupby("tipoDesvio")[["anomalia_modelo", "anomalia_limite"]].mean())
    return {
        "arquivo": caminho, "df": df, "treino": treino, "validacao": validacao, "teste": teste,
        "perfil": perfil, "detectores": detectores, "escolhido": escolhido,
        "tabela_validacao": tabela_validacao, "resultados": resultados,
        "por_tipo": por_tipo, "dias_teste": dias_teste,
    }


def periodo(parte: pd.DataFrame) -> str:
    local = parte["timestamp"].dt.tz_convert(FUSO)
    return f"{local.iloc[0]:%d/%m %H:%M} a {local.iloc[-1]:%d/%m %H:%M}"


def relatorio(r: dict) -> str:
    df, teste = r["df"], r["teste"]
    escolhido = r["escolhido"]
    det = r["detectores"][escolhido]
    linhas = [
        f"Dados: {r['arquivo'].name} - {len(df)} leituras "
        f"({(df['timestamp'].iloc[-1] - df['timestamp'].iloc[0]).total_seconds() / 86400:.1f} dias), "
        f"{df['desvioSimulado'].mean():.1%} em desvio simulado",
        f"  Treino:    {len(r['treino']):>6} leituras ({periodo(r['treino'])}), sem rótulos",
        f"  Validação: {len(r['validacao']):>6} leituras ({periodo(r['validacao'])}), escolha do modelo",
        f"  Teste:     {len(teste):>6} leituras ({periodo(teste)}), avaliação final",
        "",
        "Validação - F1 por contaminação:",
        f"{'Entradas':<16}" + "".join(f"{c:>7.2f}" for c in CONTAMINACOES),
    ]
    for nome, f1s in r["tabela_validacao"].items():
        linhas.append(f"{nome:<16}" + "".join(f"{f:>7.2f}" for f in f1s))
    linhas += [
        f"Escolhido: entradas '{escolhido}', contaminação {det.contaminacao:.2f}",
        "",
        f"Teste ({r['dias_teste']:.1f} dias, {int(teste['desvioSimulado'].sum())} leituras em desvio):",
        f"{'Método':<34}{'Precisão':>9}{'Recall':>8}{'F1':>7}{'Alarme falso (min/dia)':>24}",
    ]
    nomes = {f"anomalia_{n}": f"Isolation Forest ({n})" for n in CONJUNTOS}
    nomes["anomalia_limite"] = "Limite fixo (20 °C / 60 %)"
    for coluna, nome in nomes.items():
        m = r["resultados"][coluna]
        marca = " *" if coluna == f"anomalia_{escolhido}" else ""
        linhas.append(f"{nome + marca:<34}{m['precisao']:>9.2f}{m['recall']:>8.2f}"
                      f"{m['f1']:>7.2f}{m['falsos_por_dia']:>24.0f}")
    linhas += [
        "* modelo escolhido na validação",
        "",
        "Matriz de confusão do modelo escolhido [[VN, FP], [FN, VP]]:",
        str(confusion_matrix(teste["desvioSimulado"], teste["anomalia_modelo"]).tolist()),
        "",
        "Recall por tipo de desvio (proporção detectada no teste):",
        f"{'Tipo':<20}{'Leituras':>9}{'Modelo':>9}{'Limite':>9}",
    ]
    contagem = teste[teste["desvioSimulado"] == 1].groupby("tipoDesvio").size()
    for tipo, linha in r["por_tipo"].iterrows():
        linhas.append(f"{tipo:<20}{contagem[tipo]:>9}{linha['anomalia_modelo']:>9.0%}"
                      f"{linha['anomalia_limite']:>9.0%}")
    return "\n".join(linhas)


def resumo_repeticoes(execucoes: list) -> str:
    colunas = {f"anomalia_{n}": f"Isolation Forest ({n})" for n in CONJUNTOS}
    colunas["anomalia_limite"] = "Limite fixo (20 °C / 60 %)"
    linhas = [
        f"Repetições: {len(execucoes)} conjuntos de dados (sementes diferentes), "
        "média ± desvio padrão no teste",
        f"{'Método':<34}{'Precisão':>13}{'Recall':>13}{'F1':>13}{'Alarme falso (min/dia)':>24}",
    ]
    for coluna, nome in colunas.items():
        valores = pd.DataFrame([e["resultados"][coluna] for e in execucoes])
        linhas.append(
            f"{nome:<34}"
            + "".join(f"{valores[k].mean():>8.2f} ±{valores[k].std():.2f}"
                      for k in ("precisao", "recall", "f1"))
            + f"{valores['falsos_por_dia'].mean():>17.0f} ±{valores['falsos_por_dia'].std():.0f}"
        )
    escolhas = pd.Series([f"{e['escolhido']} / {e['detectores'][e['escolhido']].contaminacao:.2f}"
                          for e in execucoes]).value_counts()
    linhas += ["", "Escolhas na validação (entradas / contaminação):"]
    linhas += [f"  {k}: {v}x" for k, v in escolhas.items()]
    tipos = pd.concat([e["por_tipo"] for e in execucoes]).groupby(level=0).mean()
    linhas += ["", "Recall médio por tipo de desvio:", f"{'Tipo':<20}{'Modelo':>9}{'Limite':>9}"]
    for tipo, linha in tipos.iterrows():
        linhas.append(f"{tipo:<20}{linha['anomalia_modelo']:>9.0%}{linha['anomalia_limite']:>9.0%}")
    return "\n".join(linhas)


def grafico(df: pd.DataFrame, coluna_prevista: str, titulo: str, arquivo: Path):
    fig, eixos = plt.subplots(2, 1, figsize=(12, 6.5), sharex=True)
    for eixo, campo, limite, unidade in (
        (eixos[0], "temperatura", TEMPERATURA_MAX, "°C"),
        (eixos[1], "umidade", UMIDADE_MAX, "%"),
    ):
        eixo.plot(df["timestamp"], df[campo], color="black", linewidth=0.6, label="Leitura")
        eixo.axhline(limite, color="gray", linestyle="--", linewidth=1, label="Limite")
        if "desvioSimulado" in df:
            real = df[df["desvioSimulado"] == 1]
            eixo.scatter(real["timestamp"], real[campo], s=14, color="#1f77b4",
                         alpha=0.35, label="Desvio simulado (gabarito)")
        prev = df[df[coluna_prevista] == 1]
        eixo.scatter(prev["timestamp"], prev[campo], s=12, color="red",
                     marker="x", linewidths=0.8, label="Anomalia detectada (modelo)")
        eixo.set_ylabel(f"{campo.capitalize()} ({unidade})")
    eixos[0].set_title(titulo)
    eixos[0].legend(loc="upper left", fontsize=8)
    eixos[1].set_xlabel("Data e horário")
    eixos[1].xaxis.set_major_formatter(mdates.DateFormatter("%d/%m %H:%M", tz=FUSO))
    fig.tight_layout()
    fig.savefig(arquivo, dpi=150)
    plt.close(fig)


def ler_firestore(limite: int = 300) -> pd.DataFrame:
    """Lê as leituras mais recentes do histórico (apenas leitura, sem gravar).
    Considera só as do simulador calibrado (versaoSimulador = 2)."""
    url = f"{FIRESTORE_HISTORICO}?pageSize={limite}&orderBy=timestamp%20desc"
    with urllib.request.urlopen(url) as resposta:
        documentos = json.load(resposta).get("documents", [])
    linhas = []
    for doc in documentos:
        campos = doc["fields"]
        if campos.get("versaoSimulador", {}).get("integerValue") != "2":
            continue
        linhas.append({
            "timestamp": campos["timestamp"]["timestampValue"],
            "temperatura": float(campos["temperatura"].get("doubleValue", 0)),
            "umidade": float(campos["umidade"].get("doubleValue", 0)),
            "desvioSimulado": int(campos["desvioSimulado"]["booleanValue"]),
            "tipoDesvio": campos.get("tipoDesvio", {}).get("stringValue", ""),
        })
    df = pd.DataFrame(linhas)
    if not df.empty:
        df["timestamp"] = pd.to_datetime(df["timestamp"], format="ISO8601", utc=True)
    return df


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--csv", default=str(CSV_PADRAO))
    parser.add_argument("--repeticoes", action="store_true")
    parser.add_argument("--firebase", action="store_true")
    args = parser.parse_args()

    r = avaliar(Path(args.csv))
    texto = relatorio(r)
    grafico(r["teste"], "anomalia_modelo",
            f"Isolation Forest ({r['escolhido']}) - dados simulados calibrados (conjunto de teste)",
            PASTA / "resultado_simulado.png")

    if args.repeticoes:
        arquivos = sorted(PASTA_REPETICOES.glob("dados_*.csv"))
        if arquivos:
            execucoes = [avaliar(a) for a in arquivos]
            texto += "\n\n" + resumo_repeticoes(execucoes)
        else:
            texto += "\n\nRepetições: nenhum arquivo em ml/repeticoes."

    if args.firebase:
        reais = ler_firestore()
        if reais.empty:
            texto += "\n\nFirestore: nenhuma leitura do simulador calibrado encontrada."
        else:
            reais = aplicar_perfil(calcular_entradas(reais), r["perfil"])
            reais["anomalia_modelo"] = r["detectores"][r["escolhido"]].prever(reais)
            m = metricas(reais["desvioSimulado"], reais["anomalia_modelo"])
            texto += (f"\n\nFirestore: {len(reais)} leituras analisadas, "
                      f"{int(reais['anomalia_modelo'].sum())} anomalias detectadas, "
                      f"{int(reais['desvioSimulado'].sum())} desvios simulados. "
                      f"Precisão {m['precisao']:.2f}, recall {m['recall']:.2f}, F1 {m['f1']:.2f}.")
            grafico(reais, "anomalia_modelo", "Isolation Forest - histórico do Firestore",
                    PASTA / "resultado_firestore.png")

    print(texto)
    (PASTA / "resultados.txt").write_text(texto + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
