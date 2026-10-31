"""Calibra o comportamento normal do simulador com a ficha FOR 6.3.3 (agosto/2026).

Método dos momentos simulados: o modelo do simulador gera semanas de leituras
e "preenche" uma ficha como a do laboratório (7h35 e 16h10, de segunda a sexta,
com mínima e máxima desde a leitura anterior). Os parâmetros são ajustados até
as estatísticas dessa ficha simulada ficarem próximas das da ficha real.

Uso:
    python ml/calibrar_simulador.py                 # ajusta os parâmetros
    python ml/calibrar_simulador.py --validar CSV   # confere um CSV gerado pelo simulador em Dart
                                                    # (dart run bin/simulador_esp32.dart --csv 322560 --sem-desvios --saida CSV)
"""

import argparse
import json
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
import pandas as pd
from scipy.optimize import minimize
from scipy.signal import lfilter

PASTA = Path(__file__).parent
FICHA = PASTA / "ficha_for633_agosto2026.csv"
PARAMETROS = PASTA / "parametros_calibrados.json"

LEITURAS_POR_HORA = 240  # uma a cada 15 s
PASSOS_DIA = 24 * LEITURAS_POR_HORA
RETORNO = 0.1  # retorno à curva normal por leitura (igual ao simulador)
HORA_MANHA = 7 + 35 / 60  # horários médios das leituras na ficha
HORA_TARDE = 16 + 10 / 60
SEMANAS = 30
SEMENTE = 7
FUSO = "America/Sao_Paulo"
TEMPERATURA_MAX = 20.0
UMIDADE_MAX = 60.0

ESTATISTICAS = [
    ("manha_atual", "Manhã - leitura atual (média)"),
    ("manha_atual_dp", "Manhã - leitura atual (desvio padrão)"),
    ("tarde_atual", "Tarde - leitura atual (média)"),
    ("tarde_atual_dp", "Tarde - leitura atual (desvio padrão)"),
    ("manha_min", "Manhã - mínima desde a tarde anterior (média)"),
    ("manha_max", "Manhã - máxima desde a tarde anterior (média)"),
    ("tarde_min", "Tarde - mínima desde a manhã (média)"),
    ("tarde_max", "Tarde - máxima desde a manhã (média)"),
]

PARAM_TEMPERATURA = [
    # nome, limites, descrição
    ("temp_min", (15, 20), "temperatura no ponto mais frio do dia (°C)"),
    ("amplitude", (0, 6), "subida média até o pico do dia (°C)"),
    ("dp_temp", (0, 2), "variação de um dia para outro na temperatura mínima (°C)"),
    ("dp_amplitude", (0, 3), "variação de um dia para outro na subida (°C)"),
    ("hora_min", (2, 11.5), "hora do ponto mais frio"),
    ("hora_pico", (12.5, 23.5), "hora do pico"),
    ("ruido_temp", (0.01, 0.6), "oscilação por leitura (°C)"),
]
PARAM_UMIDADE = [
    ("umid_max", (45, 70), "umidade no ponto mais frio do dia (%)"),
    ("queda_umid", (0, 6), "queda da umidade por grau de subida no dia médio (%/°C)"),
    ("dp_umid", (0, 5), "variação de um dia para outro na umidade (%)"),
    ("ruido_umid", (0.05, 3), "oscilação por leitura (%)"),
]


def estatisticas(ficha: pd.DataFrame, var: str) -> np.ndarray:
    m = ficha[ficha["periodo"] == "manha"]
    t = ficha[ficha["periodo"] == "tarde"]
    return np.array([
        m[f"{var}_atual"].mean(), m[f"{var}_atual"].std(),
        t[f"{var}_atual"].mean(), t[f"{var}_atual"].std(),
        m[f"{var}_min"].mean(), m[f"{var}_max"].mean(),
        t[f"{var}_min"].mean(), t[f"{var}_max"].mean(),
    ])


def erros_padrao(ficha: pd.DataFrame, var: str) -> np.ndarray:
    """Erro padrão de cada estatística da ficha real (peso no ajuste)."""
    m = ficha[ficha["periodo"] == "manha"]
    t = ficha[ficha["periodo"] == "tarde"]
    n = len(m)
    ep = np.array([
        m[f"{var}_atual"].std() / np.sqrt(n), m[f"{var}_atual"].std() / np.sqrt(2 * (n - 1)),
        t[f"{var}_atual"].std() / np.sqrt(n), t[f"{var}_atual"].std() / np.sqrt(2 * (n - 1)),
        m[f"{var}_min"].std() / np.sqrt(n), m[f"{var}_max"].std() / np.sqrt(n),
        t[f"{var}_min"].std() / np.sqrt(n), t[f"{var}_max"].std() / np.sqrt(n),
    ])
    return np.maximum(ep, 0.05)


def forma_diaria(hora, hora_min, hora_pico):
    """0 no ponto mais frio, 1 no pico; subida e descida em meio cosseno."""
    subida = (hora_pico - hora_min) % 24
    u = (hora - hora_min) % 24
    return np.where(
        u < subida,
        (1 - np.cos(np.pi * u / subida)) / 2,
        (1 + np.cos(np.pi * (u - subida) / (24 - subida))) / 2,
    )


class Simulacao:
    """Semanas simuladas com números aleatórios fixos, para comparar
    parâmetros diferentes sob a mesma sorte."""

    def __init__(self, semanas=SEMANAS, semente=SEMENTE):
        rng = np.random.default_rng(semente)
        dias = semanas * 7
        passo = np.arange(dias * PASSOS_DIA)
        self.hora = (passo % PASSOS_DIA) / LEITURAS_POR_HORA
        dia = passo // PASSOS_DIA
        frac = self.hora / 24
        # Sorteio diário (temperatura mínima, subida, umidade), interpolado ao longo do dia
        z = rng.standard_normal((3, dias + 1))
        self.z = z[:, dia] + (z[:, dia + 1] - z[:, dia]) * frac
        self.e = rng.uniform(-1, 1, (2, len(passo)))

        # Leituras da ficha: segunda a sexta (dia % 7 < 5), a partir da 2ª semana
        manha = round(HORA_MANHA * LEITURAS_POR_HORA)
        tarde = round(HORA_TARDE * LEITURAS_POR_HORA)
        idx = [d * PASSOS_DIA + h for d in range(7, dias) if d % 7 < 5 for h in (manha, tarde)]
        self.idx = np.array(idx)
        self.periodo = np.array(["manha", "tarde"] * (len(idx) // 2))
        # Leitura anterior da primeira: sexta à tarde da semana inicial
        self.anterior = np.concatenate([[4 * PASSOS_DIA + tarde], self.idx[:-1]])


def elevacao(sim, p):
    f = forma_diaria(sim.hora, p["hora_min"], p["hora_pico"])
    amplitude = np.maximum(0, p["amplitude"] + p["dp_amplitude"] * sim.z[1])
    return amplitude * f


def curva_temperatura(sim, p, elev):
    return p["temp_min"] + p["dp_temp"] * sim.z[0] + elev


def ciclo_medio(sim, p):
    """Subida da temperatura num dia médio (sem a variação entre dias)."""
    return p["amplitude"] * forma_diaria(sim.hora, p["hora_min"], p["hora_pico"])


def curva_umidade(sim, p, ciclo):
    # Segue o ciclo médio: na ficha, a umidade quase não acompanha a variação da temperatura entre dias.
    return p["umid_max"] + p["dp_umid"] * sim.z[2] - p["queda_umid"] * ciclo


def serie(alvo, ruido, e):
    """Mesma regra do simulador: valor += (alvo - valor) * 0,1 + ruído."""
    entrada = RETORNO * alvo + ruido * e
    return lfilter([1], [1, -(1 - RETORNO)], entrada, zi=[(1 - RETORNO) * alvo[0]])[0]


def ficha_de_serie(valores, idx, anterior, periodo, var):
    inicio = np.append(anterior + 1, idx[-1] + 1)
    return pd.DataFrame({
        "periodo": periodo,
        f"{var}_atual": valores[idx],
        f"{var}_min": np.minimum.reduceat(valores, inicio)[:-1],
        f"{var}_max": np.maximum.reduceat(valores, inicio)[:-1],
    })


def ajustar(objetivo, especificacao, inicios):
    limites = [lim for _, lim, _ in especificacao]
    melhor = None
    for x0 in inicios:
        r = minimize(objetivo, x0, method="Nelder-Mead", bounds=limites,
                     options={"maxiter": 3000, "xatol": 1e-3, "fatol": 1e-4})
        if melhor is None or r.fun < melhor.fun:
            melhor = r
    return dict(zip([n for n, _, _ in especificacao], melhor.x)), melhor.fun


def calibrar(real):
    sim = Simulacao()
    alvo_t, ep_t = estatisticas(real, "temp"), erros_padrao(real, "temp")
    alvo_u, ep_u = estatisticas(real, "umid"), erros_padrao(real, "umid")
    nomes_t = [n for n, _, _ in PARAM_TEMPERATURA]
    nomes_u = [n for n, _, _ in PARAM_UMIDADE]

    def obj_temp(x):
        p = dict(zip(nomes_t, x))
        valores = serie(curva_temperatura(sim, p, elevacao(sim, p)), p["ruido_temp"], sim.e[0])
        f = ficha_de_serie(valores, sim.idx, sim.anterior, sim.periodo, "temp")
        return np.sum(((estatisticas(f, "temp") - alvo_t) / ep_t) ** 2)

    p_t, erro_t = ajustar(obj_temp, PARAM_TEMPERATURA, [
        [17.5, 2.8, 0.3, 1.2, 8.0, 19.0, 0.15],
        [17.3, 3.5, 0.5, 1.0, 6.0, 20.0, 0.10],
        [17.8, 2.2, 0.2, 1.5, 9.5, 17.5, 0.30],
    ])
    ciclo = ciclo_medio(sim, p_t)

    def obj_umid(x):
        p = dict(zip(nomes_u, x))
        valores = serie(curva_umidade(sim, p, ciclo), p["ruido_umid"], sim.e[1])
        f = ficha_de_serie(valores, sim.idx, sim.anterior, sim.periodo, "umid")
        return np.sum(((estatisticas(f, "umid") - alvo_u) / ep_u) ** 2)

    p_u, erro_u = ajustar(obj_umid, PARAM_UMIDADE, [
        [57.0, 2.5, 1.0, 0.5],
        [56.0, 3.0, 0.5, 0.8],
        [58.0, 2.0, 1.5, 0.3],
    ])
    return {**p_t, **p_u}, erro_t, erro_u


def simular_ficha(p, semanas=SEMANAS, semente=SEMENTE + 1):
    """Ficha simulada com sorte diferente da usada no ajuste."""
    sim = Simulacao(semanas, semente)
    elev = elevacao(sim, p)
    temp = serie(curva_temperatura(sim, p, elev), p["ruido_temp"], sim.e[0])
    umid = serie(curva_umidade(sim, p, ciclo_medio(sim, p)), p["ruido_umid"], sim.e[1])
    ft = ficha_de_serie(temp, sim.idx, sim.anterior, sim.periodo, "temp")
    fu = ficha_de_serie(umid, sim.idx, sim.anterior, sim.periodo, "umid")
    return pd.concat([ft, fu.drop(columns="periodo")], axis=1), sim, temp, umid


def ficha_de_csv(caminho: Path) -> pd.DataFrame:
    """Ficha a partir de um CSV do simulador em Dart (leituras às 7h35 e 16h10, seg-sex)."""
    df = pd.read_csv(caminho, keep_default_na=False)
    local = pd.to_datetime(df["timestamp"], format="ISO8601", utc=True).dt.tz_convert(FUSO)
    minuto = local.dt.hour * 60 + local.dt.minute
    segundo = local.dt.second
    util = local.dt.day_of_week < 5
    leitura = util & (segundo == 0) & minuto.isin([7 * 60 + 35, 16 * 60 + 10])
    idx = np.flatnonzero(leitura.to_numpy())
    periodo = np.where(minuto.to_numpy()[idx] < 12 * 60, "manha", "tarde")
    # Descarta a primeira leitura (não há leitura anterior)
    anterior, idx, periodo = idx[:-1], idx[1:], periodo[1:]
    ft = ficha_de_serie(df["temperatura"].to_numpy(float), idx, anterior, periodo, "temp")
    fu = ficha_de_serie(df["umidade"].to_numpy(float), idx, anterior, periodo, "umid")
    return pd.concat([ft, fu.drop(columns="periodo")], axis=1)


def tabela(real, *simuladas, nomes):
    linhas = [f"{'Estatística':<48}{'Real':>8}" + "".join(f"{n:>12}" for n in nomes) + f"{'Erro padrão':>13}"]
    for var, unidade in (("temp", "°C"), ("umid", "%")):
        linhas.append(f"-- {'Temperatura' if var == 'temp' else 'Umidade'} ({unidade})")
        r, ep = estatisticas(real, var), erros_padrao(real, var)
        s = [estatisticas(f, var) for f in simuladas]
        for i, (_, rotulo) in enumerate(ESTATISTICAS):
            linhas.append(f"{rotulo:<48}{r[i]:>8.2f}" + "".join(f"{x[i]:>12.2f}" for x in s) + f"{ep[i]:>13.2f}")
    return "\n".join(linhas)


def evidencias(real: pd.DataFrame) -> str:
    m = real[real["periodo"] == "manha"].reset_index(drop=True)
    t = real[real["periodo"] == "tarde"].reset_index(drop=True)
    tarde_mais_quente = int((t["temp_atual"] > m["temp_atual"]).sum())
    tarde_mais_seca = int((t["umid_atual"] < m["umid_atual"]).sum())
    # Noite de dia útil: máxima da manhã seguinte acima da leitura da tarde anterior
    consecutivos = pd.to_datetime(m["data"]).diff().dt.days.eq(1)
    noites = int(consecutivos.sum())
    subiu = int(((m["temp_max"] > t["temp_atual"].shift(1)) & consecutivos).sum())
    caiu_de_manha = int((t["temp_min"] < m["temp_atual"]).sum())
    dt = t["temp_atual"] - m["temp_atual"]
    du = t["umid_atual"] - m["umid_atual"]
    queda = -du.mean() / dt.mean()
    corr = np.corrcoef(dt, du)[0, 1]
    return "\n".join([
        f"Tarde mais quente que a manhã: {tarde_mais_quente} de {len(t)} dias",
        f"Tarde mais seca que a manhã: {tarde_mais_seca} de {len(t)} dias",
        f"Temperatura continuou subindo depois da leitura da tarde (máxima da manhã seguinte maior): {subiu} de {noites} noites",
        f"Temperatura caiu depois da leitura da manhã (mínima da tarde menor que a leitura da manhã): "
        f"{caiu_de_manha} de {len(t)} dias",
        f"Da manhã para a tarde, a umidade cai em média {queda:.2f} % por °C de subida; "
        f"entre dias, a correlação entre as duas variações é fraca ({corr:.2f})",
    ])


def grafico(p, sim, temp, umid, real, arquivo):
    hora_dia = sim.hora[:PASSOS_DIA]
    dias = len(temp) // PASSOS_DIA
    fig, eixos = plt.subplots(2, 1, figsize=(10, 6.5), sharex=True)
    hora_real = real["hora"].str.split(":").apply(lambda x: int(x[0]) + int(x[1]) / 60)
    for eixo, valores, campo, limite, unidade, nome in (
        (eixos[0], temp, "temp_atual", TEMPERATURA_MAX, "°C", "Temperatura"),
        (eixos[1], umid, "umid_atual", UMIDADE_MAX, "%", "Umidade"),
    ):
        por_dia = valores[PASSOS_DIA * 7:PASSOS_DIA * dias].reshape(-1, PASSOS_DIA)
        p10, p50, p90 = np.percentile(por_dia, [10, 50, 90], axis=0)
        eixo.fill_between(hora_dia, p10, p90, color="#1f77b4", alpha=0.25,
                          label="Simulador calibrado (80% dos dias)")
        eixo.plot(hora_dia, p50, color="#1f77b4", linewidth=1.5, label="Simulador calibrado (mediana)")
        eixo.scatter(hora_real, real[campo], color="black", s=22, zorder=3,
                     label="Ficha FOR 6.3.3 (leitura atual)")
        eixo.axhline(limite, color="gray", linestyle="--", linewidth=1, label="Limite")
        eixo.set_ylabel(f"{nome} ({unidade})")
    eixos[0].set_title("Ciclo diário: ficha do laboratório × simulador calibrado")
    eixos[0].legend(loc="upper left", fontsize=8)
    eixos[1].set_xlabel("Hora do dia")
    eixos[1].set_xticks(range(0, 25, 2))
    eixos[1].set_xlim(0, 24)
    fig.tight_layout()
    fig.savefig(arquivo, dpi=150)
    plt.close(fig)


def bloco_dart(p) -> str:
    return "\n".join([
        f"const double temperaturaMinimaDia = {p['temp_min']:.2f};",
        f"const double subidaDia = {p['amplitude']:.2f};",
        f"const double variacaoTemperaturaDia = {p['dp_temp']:.2f};",
        f"const double variacaoSubidaDia = {p['dp_amplitude']:.2f};",
        f"const double horaMaisFria = {p['hora_min']:.2f};",
        f"const double horaPico = {p['hora_pico']:.2f};",
        f"const double ruidoTemperatura = {p['ruido_temp']:.3f};",
        f"const double umidadeMaximaDia = {p['umid_max']:.2f};",
        f"const double quedaUmidadePorGrau = {p['queda_umid']:.2f};",
        f"const double variacaoUmidadeDia = {p['dp_umid']:.2f};",
        f"const double ruidoUmidade = {p['ruido_umid']:.3f};",
    ])


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--validar", help="CSV do simulador em Dart, gerado com --sem-desvios")
    args = parser.parse_args()
    if not FICHA.exists():
        print(f"{FICHA.name} não encontrada. A ficha da empresa fica fora do repositório; "
              "os parâmetros já calibrados estão em parametros_calibrados.json e no simulador.")
        return
    real = pd.read_csv(FICHA, dtype={"hora": str})

    if args.validar:
        p = json.loads(PARAMETROS.read_text(encoding="utf-8"))
        python, _, _, _ = simular_ficha(p)
        dart = ficha_de_csv(Path(args.validar))
        texto = (f"Validação do simulador em Dart ({len(dart) // 2} dias úteis)\n\n"
                 + tabela(real, python, dart, nomes=["Python", "Dart"]))
        print(texto)
        (PASTA / "calibracao_validacao.txt").write_text(texto + "\n", encoding="utf-8")
        return

    p, erro_t, erro_u = calibrar(real)
    PARAMETROS.write_text(json.dumps({k: round(float(v), 4) for k, v in p.items()}, indent=2),
                          encoding="utf-8")
    ficha_sim, sim, temp, umid = simular_ficha(p)

    linhas = ["Calibração do simulador com a ficha FOR 6.3.3 (agosto/2026, 10 dias úteis)", "",
              "Evidências na ficha:", evidencias(real), "",
              "Parâmetros ajustados:"]
    for nome, _, descricao in PARAM_TEMPERATURA + PARAM_UMIDADE:
        linhas.append(f"  {nome:<14}{p[nome]:>8.2f}   {descricao}")
    linhas += ["", f"Erro do ajuste (soma dos quadrados em erros padrão): temperatura {erro_t:.2f}, "
               f"umidade {erro_u:.2f} (16 estatísticas, 11 parâmetros)", "",
               "Ficha real × ficha simulada (sorte diferente da usada no ajuste, "
               f"{len(ficha_sim) // 2} dias úteis):",
               tabela(real, ficha_sim, nomes=["Simulada"]), "",
               "Constantes para bin/simulador_esp32.dart:", bloco_dart(p)]
    texto = "\n".join(linhas)
    print(texto)
    (PASTA / "calibracao.txt").write_text(texto + "\n", encoding="utf-8")
    grafico(p, sim, temp, umid, real, PASTA / "calibracao.png")
    print(f"\nGráfico: {PASTA / 'calibracao.png'}")


if __name__ == "__main__":
    main()
