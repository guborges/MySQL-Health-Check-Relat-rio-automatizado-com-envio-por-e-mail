#!/bin/bash
# ============================================================
# MySQL Health Check - Coleta + Relatorio HTML + Envio por Email
# ============================================================
# Uso: ./mysql_healthcheck.sh
# Cron: 0 8 * * * /tmp/mysql_healthcheck.sh >> /tmp/logs/healthcheck_cron.log 2>&1
# ============================================================

# --- CONFIGURACOES ---
MYSQL_USER="root"
MYSQL_PASS='SUA_SENHA_AQUI'
MYSQL_HOST="localhost"
MYSQL_PORT="3306"
MYSQL_CMD="mysql -u${MYSQL_USER} -p${MYSQL_PASS} -h${MYSQL_HOST} -P${MYSQL_PORT} -N -B"

LOG_DIR="/tmp/logs"
mkdir -p ${LOG_DIR}

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
HTML_FILE="${LOG_DIR}/mysql_healthcheck_${TIMESTAMP}.html"
HTML_LATEST="${LOG_DIR}/mysql_healthcheck_latest.html"

HOSTNAME_SERVER=$(hostname)
DATA_HOJE=$(date '+%d/%m/%Y')
HORA_HOJE=$(date '+%H:%M')
DATA_AMANHA=$(date -d '+1 day' '+%d/%m/%Y')

# --- EMAIL ---
SEND_EMAIL="/usr/bin/perl /home/mysqlemail/sendEmail"
EMAIL_FROM="servidor@suaempresa.com.br"
EMAIL_TO="-t destinatario1@empresa.com.br \
-t destinatario2@empresa.com.br \
-t destinatario3@empresa.com.br"
EMAIL_SUBJECT="MySQL Health Check - ${HOSTNAME_SERVER} - ${DATA_HOJE}"

# ============================================================
# FUNCAO: Executar SQL e retornar resultado
# ============================================================
run_sql() {
  echo "$1" | ${MYSQL_CMD} 2>/dev/null
}

# ============================================================
# COLETA DE DADOS
# ============================================================
echo "[$(date)] Iniciando coleta de dados..."

# --- Versao e Config ---
MYSQL_VERSION=$(run_sql "SELECT @@version;")
MYSQL_HOSTNAME=$(run_sql "SELECT @@hostname;")
MYSQL_DATADIR=$(run_sql "SELECT @@datadir;")
BUFFER_POOL_SIZE_BYTES=$(run_sql "SELECT @@innodb_buffer_pool_size;")
BUFFER_POOL_SIZE_GB=$(awk "BEGIN {printf \"%.2f\", ${BUFFER_POOL_SIZE_BYTES:-0} / 1024 / 1024 / 1024}")
MAX_CONNECTIONS=$(run_sql "SELECT @@max_connections;")
SLOW_QUERY_LOG=$(run_sql "SELECT @@slow_query_log;")
PERF_SCHEMA=$(run_sql "SELECT @@performance_schema;")
FLUSH_COMMIT=$(run_sql "SELECT @@innodb_flush_log_at_trx_commit;")
BIND_ADDRESS=$(run_sql "SELECT @@bind_address;")
SECURE_TRANSPORT=$(run_sql "SELECT COALESCE(@@require_secure_transport, 'OFF');")
LOG_FILE_SIZE=$(run_sql "SELECT ROUND(@@innodb_log_file_size / 1024 / 1024, 0);")

# --- Uptime ---
UPTIME_SECONDS=$(run_sql "SHOW STATUS LIKE 'Uptime';" | awk '{print $2}')
UPTIME_SECONDS=${UPTIME_SECONDS:-0}
UPTIME_DAYS=$(awk "BEGIN {printf \"%d\", ${UPTIME_SECONDS} / 86400}")
UPTIME_HOURS=$(awk "BEGIN {printf \"%d\", (${UPTIME_SECONDS} % 86400) / 3600}")
UPTIME_MINS=$(awk "BEGIN {printf \"%d\", (${UPTIME_SECONDS} % 3600) / 60}")

# Calcular disponibilidade (uptime%) - considerando janela de 30 dias
TOTAL_30D=$((30 * 86400))
if [ ${UPTIME_SECONDS} -ge ${TOTAL_30D} ]; then
  UPTIME_PCT="99.99"
else
  UPTIME_PCT=$(awk "BEGIN {printf \"%.2f\", ${UPTIME_SECONDS} * 100 / ${TOTAL_30D}}")
fi

# --- Conexoes ---
THREADS_CONNECTED=$(run_sql "SHOW STATUS LIKE 'Threads_connected';" | awk '{print $2}')
THREADS_RUNNING=$(run_sql "SHOW STATUS LIKE 'Threads_running';" | awk '{print $2}')
MAX_USED_CONN=$(run_sql "SHOW STATUS LIKE 'Max_used_connections';" | awk '{print $2}')
CONN_PCT=$(awk "BEGIN {printf \"%d\", ${MAX_USED_CONN:-0} * 100 / ${MAX_CONNECTIONS:-151}}")

# --- Buffer Pool Hit Ratio ---
BP_READS=$(run_sql "SHOW STATUS LIKE 'Innodb_buffer_pool_reads';" | awk '{print $2}')
BP_READ_REQ=$(run_sql "SHOW STATUS LIKE 'Innodb_buffer_pool_read_requests';" | awk '{print $2}')
if [ "${BP_READ_REQ:-0}" -gt 0 ] 2>/dev/null; then
  BP_HIT_RATIO=$(awk "BEGIN {printf \"%.2f\", (1 - ${BP_READS:-0} / ${BP_READ_REQ}) * 100}")
else
  BP_HIT_RATIO="N/A"
fi

# --- Queries por segundo ---
QUESTIONS=$(run_sql "SHOW STATUS LIKE 'Questions';" | awk '{print $2}')
if [ ${UPTIME_SECONDS} -gt 0 ] 2>/dev/null; then
  QPS=$(awk "BEGIN {printf \"%d\", ${QUESTIONS:-0} / ${UPTIME_SECONDS}}")
else
  QPS="0"
fi

# --- InnoDB Metrics ---
INNODB_ROWS_READ=$(run_sql "SHOW STATUS LIKE 'Innodb_rows_read';" | awk '{print $2}')
INNODB_ROWS_INSERTED=$(run_sql "SHOW STATUS LIKE 'Innodb_rows_inserted';" | awk '{print $2}')
INNODB_ROWS_UPDATED=$(run_sql "SHOW STATUS LIKE 'Innodb_rows_updated';" | awk '{print $2}')
INNODB_ROWS_DELETED=$(run_sql "SHOW STATUS LIKE 'Innodb_rows_deleted';" | awk '{print $2}')
INNODB_ROW_LOCK_WAITS=$(run_sql "SHOW STATUS LIKE 'Innodb_row_lock_waits';" | awk '{print $2}')
INNODB_ROW_LOCK_WAITS=${INNODB_ROW_LOCK_WAITS:-0}

READS_PER_SEC=$(awk "BEGIN {printf \"%d\", ${INNODB_ROWS_READ:-0} / ${UPTIME_SECONDS:-1}}")
WRITES_PER_SEC=$(awk "BEGIN {printf \"%d\", (${INNODB_ROWS_INSERTED:-0} + ${INNODB_ROWS_UPDATED:-0} + ${INNODB_ROWS_DELETED:-0}) / ${UPTIME_SECONDS:-1}}")

# --- Disco ---
DISK_TOTAL=$(df -BG "${MYSQL_DATADIR}" 2>/dev/null | tail -1 | awk '{gsub("G",""); print $2}')
DISK_USED=$(df -BG "${MYSQL_DATADIR}" 2>/dev/null | tail -1 | awk '{gsub("G",""); print $3}')
DISK_AVAIL=$(df -BG "${MYSQL_DATADIR}" 2>/dev/null | tail -1 | awk '{gsub("G",""); print $4}')
DISK_PCT=$(df "${MYSQL_DATADIR}" 2>/dev/null | tail -1 | awk '{gsub("%",""); print $5}')
DISK_PCT=${DISK_PCT:-0}

# --- Databases ---
DB_DATA=$(run_sql "
SELECT table_schema,
  ROUND(SUM(data_length + index_length) / 1024 / 1024, 2),
  COUNT(*),
  ROUND(SUM(data_free) / 1024 / 1024, 2)
FROM information_schema.tables
WHERE table_schema NOT IN ('information_schema','performance_schema','sys')
GROUP BY table_schema
ORDER BY SUM(data_length + index_length) DESC
LIMIT 10;")

# --- Tabelas sem PK ---
NO_PK_COUNT=$(run_sql "
SELECT COUNT(*)
FROM information_schema.tables t
LEFT JOIN information_schema.table_constraints tc
  ON t.table_schema = tc.table_schema
  AND t.table_name = tc.table_name
  AND tc.constraint_type = 'PRIMARY KEY'
WHERE tc.constraint_name IS NULL
  AND t.table_schema NOT IN ('mysql','information_schema','performance_schema','sys')
  AND t.table_type = 'BASE TABLE';")
NO_PK_COUNT=${NO_PK_COUNT:-0}

# --- Tabelas MyISAM ---
MYISAM_COUNT=$(run_sql "
SELECT COUNT(*)
FROM information_schema.tables
WHERE engine = 'MyISAM'
  AND table_schema NOT IN ('mysql','information_schema','performance_schema','sys');")
MYISAM_COUNT=${MYISAM_COUNT:-0}

# --- Replicacao ---
REPLICA_STATUS=$(run_sql "SHOW REPLICA STATUS\G")
if [ -z "${REPLICA_STATUS}" ]; then
  REPLICA_STATUS=$(run_sql "SHOW SLAVE STATUS\G")
fi

if [ -n "${REPLICA_STATUS}" ]; then
  REPLICA_IO=$(echo "${REPLICA_STATUS}" | grep -E "Replica_IO_Running:|Slave_IO_Running:" | head -1 | awk -F': ' '{print $2}' | tr -d ' ')
  REPLICA_SQL=$(echo "${REPLICA_STATUS}" | grep -E "Replica_SQL_Running:|Slave_SQL_Running:" | head -1 | awk -F': ' '{print $2}' | tr -d ' ')
  REPLICA_LAG=$(echo "${REPLICA_STATUS}" | grep -E "Seconds_Behind_Source:|Seconds_Behind_Master:" | head -1 | awk -F': ' '{print $2}' | tr -d ' ')
  HAS_REPLICA="YES"
else
  HAS_REPLICA="NO"
fi

# --- Binary Logs ---
BINLOG_COUNT=$(run_sql "SHOW BINARY LOGS;" | wc -l)
BINLOG_SIZE=$(run_sql "SHOW BINARY LOGS;" | awk '{sum+=$2} END {printf "%.2f", sum/1024/1024}')

# --- Usuarios ---
USER_COUNT=$(run_sql "SELECT COUNT(DISTINCT user) FROM mysql.user WHERE user != '';")
SUPER_COUNT=$(run_sql "SELECT COUNT(*) FROM mysql.user WHERE Super_priv='Y' AND user != '';")

# --- Slow Queries ---
SLOW_QUERIES=$(run_sql "SHOW STATUS LIKE 'Slow_queries';" | awk '{print $2}')
SLOW_QUERIES=${SLOW_QUERIES:-0}

# --- Top Queries do Performance Schema ---
TOP_QUERIES=""
if [ "${PERF_SCHEMA}" = "1" ]; then
  TOP_QUERIES=$(run_sql "
SELECT
  LEFT(DIGEST_TEXT, 80),
  COUNT_STAR,
  ROUND(AVG_TIMER_WAIT / 1000000000000, 3),
  SUM_ROWS_EXAMINED
FROM performance_schema.events_statements_summary_by_digest
WHERE SCHEMA_NAME NOT IN ('mysql','information_schema','performance_schema','sys')
  AND DIGEST_TEXT IS NOT NULL
  AND DIGEST_TEXT NOT LIKE 'SHOW%'
  AND DIGEST_TEXT NOT LIKE 'SET%'
  AND DIGEST_TEXT NOT LIKE 'SELECT @@%'
ORDER BY AVG_TIMER_WAIT DESC
LIMIT 5;")
fi

# --- Tabelas mais fragmentadas ---
FRAG_TABLES=$(run_sql "
SELECT table_schema, table_name,
  ROUND((data_length + index_length) / 1024 / 1024, 2),
  ROUND(data_free / 1024 / 1024, 2),
  ROUND(data_free / (data_length + index_length) * 100, 1)
FROM information_schema.tables
WHERE data_free > 0
  AND (data_length + index_length) > 1048576
  AND table_schema NOT IN ('mysql','information_schema','performance_schema','sys')
  AND data_free / (data_length + index_length) > 0.10
ORDER BY data_free DESC
LIMIT 5;")

echo "[$(date)] Coleta finalizada. Gerando HTML..."

# ============================================================
# DETERMINAR STATUS GERAL
# ============================================================
OVERALL_STATUS="OPERATIONAL"
OVERALL_COLOR="#10b981"
OVERALL_BG="rgba(16,185,129,0.1)"
OVERALL_BORDER="rgba(16,185,129,0.25)"
ALERT_MESSAGES=""

# Checar disco
if [ ${DISK_PCT} -ge 90 ] 2>/dev/null; then
  OVERALL_STATUS="CRITICO"
  OVERALL_COLOR="#ef4444"
  OVERALL_BG="rgba(239,68,68,0.1)"
  OVERALL_BORDER="rgba(239,68,68,0.25)"
  ALERT_MESSAGES="${ALERT_MESSAGES}<div class='alert-strip critical'>&#9888;&#65039; <strong>CRITICO:</strong>&nbsp; Disco em ${DISK_PCT}% — risco iminente de indisponibilidade. Acao urgente necessaria.</div>"
elif [ ${DISK_PCT} -ge 80 ] 2>/dev/null; then
  OVERALL_STATUS="ATENCAO"
  OVERALL_COLOR="#f59e0b"
  OVERALL_BG="rgba(245,158,11,0.1)"
  OVERALL_BORDER="rgba(245,158,11,0.25)"
  ALERT_MESSAGES="${ALERT_MESSAGES}<div class='alert-strip warning'>&#9888;&#65039; <strong>Atencao:</strong>&nbsp; Disco em ${DISK_PCT}% — planejar expansao.</div>"
elif [ ${DISK_PCT} -ge 70 ] 2>/dev/null; then
  ALERT_MESSAGES="${ALERT_MESSAGES}<div class='alert-strip info'>&#8505;&#65039; <strong>Capacity:</strong>&nbsp; Disco em ${DISK_PCT}% — monitorar crescimento.</div>"
fi

# Checar buffer pool
if [ "${BP_HIT_RATIO}" != "N/A" ]; then
  BP_INT=$(echo "${BP_HIT_RATIO}" | awk -F'.' '{print $1}')
  if [ ${BP_INT:-0} -lt 95 ] 2>/dev/null; then
    ALERT_MESSAGES="${ALERT_MESSAGES}<div class='alert-strip warning'>&#9888;&#65039; <strong>Performance:</strong>&nbsp; Buffer Pool Hit Ratio em ${BP_HIT_RATIO}% — abaixo do ideal (&gt;99%). Avaliar aumento do innodb_buffer_pool_size.</div>"
  fi
fi

# Checar tabelas sem PK
if [ ${NO_PK_COUNT} -gt 0 ] 2>/dev/null; then
  ALERT_MESSAGES="${ALERT_MESSAGES}<div class='alert-strip info'>&#8505;&#65039; <strong>Best Practice:</strong>&nbsp; ${NO_PK_COUNT} tabela(s) sem PRIMARY KEY detectada(s).</div>"
fi

# Checar MyISAM
if [ ${MYISAM_COUNT} -gt 0 ] 2>/dev/null; then
  ALERT_MESSAGES="${ALERT_MESSAGES}<div class='alert-strip warning'>&#9888;&#65039; <strong>Engine:</strong>&nbsp; ${MYISAM_COUNT} tabela(s) usando MyISAM — candidatas a migracao para InnoDB.</div>"
fi

# Checar replicacao
if [ "${HAS_REPLICA}" = "YES" ]; then
  if [ "${REPLICA_IO}" != "Yes" ] || [ "${REPLICA_SQL}" != "Yes" ]; then
    OVERALL_STATUS="CRITICO"
    OVERALL_COLOR="#ef4444"
    OVERALL_BG="rgba(239,68,68,0.1)"
    OVERALL_BORDER="rgba(239,68,68,0.25)"
    ALERT_MESSAGES="${ALERT_MESSAGES}<div class='alert-strip critical'>&#9888;&#65039; <strong>CRITICO:</strong>&nbsp; Replicacao com problemas — IO: ${REPLICA_IO}, SQL: ${REPLICA_SQL}.</div>"
  fi
  if [ "${REPLICA_LAG}" != "NULL" ] && [ ${REPLICA_LAG:-0} -gt 60 ] 2>/dev/null; then
    ALERT_MESSAGES="${ALERT_MESSAGES}<div class='alert-strip warning'>&#9888;&#65039; <strong>Replicacao:</strong>&nbsp; Lag de ${REPLICA_LAG} segundos detectado.</div>"
  fi
fi

# ============================================================
# FUNCOES AUXILIARES HTML
# ============================================================
get_bp_color() {
  local val=$(echo "$1" | awk -F'.' '{print $1}')
  if [ ${val:-0} -ge 99 ] 2>/dev/null; then echo "green"
  elif [ ${val:-0} -ge 95 ] 2>/dev/null; then echo "yellow"
  else echo "red"
  fi
}

get_bp_status() {
  local val=$(echo "$1" | awk -F'.' '{print $1}')
  if [ ${val:-0} -ge 99 ] 2>/dev/null; then echo "&#10003; Saudavel"
  elif [ ${val:-0} -ge 95 ] 2>/dev/null; then echo "&#9888; Atencao"
  else echo "&#10007; Critico"
  fi
}

get_disk_bar_color() {
  if [ ${1:-0} -ge 90 ] 2>/dev/null; then echo "red"
  elif [ ${1:-0} -ge 80 ] 2>/dev/null; then echo "yellow"
  else echo "blue"
  fi
}

if [ "${BP_HIT_RATIO}" != "N/A" ]; then
  BP_COLOR=$(get_bp_color "${BP_HIT_RATIO}")
  BP_STATUS=$(get_bp_status "${BP_HIT_RATIO}")
else
  BP_COLOR="red"
  BP_STATUS="N/A"
fi
DISK_BAR_COLOR=$(get_disk_bar_color "${DISK_PCT}")

# ============================================================
# GERAR LINHAS DAS TABELAS
# ============================================================

# --- Databases ---
DB_ROWS=""
IDX=0
while IFS=$'\t' read -r db_name db_size db_tables db_frag; do
  [ -z "${db_name}" ] && continue
  DB_ROWS="${DB_ROWS}<tr>
    <td style='color:#f0f4f8;font-weight:500'>${db_name}</td>
    <td class='mono'>${db_size} MB</td>
    <td>${db_tables}</td>
    <td>${db_frag} MB</td>
  </tr>"
  IDX=$((IDX + 1))
done <<< "${DB_DATA}"

# --- Top Queries ---
QUERY_ROWS=""
QIDX=1
while IFS=$'\t' read -r q_text q_count q_avg q_rows; do
  [ -z "${q_text}" ] && continue
  Q_AVG_INT=$(echo "${q_avg}" | awk -F'.' '{print $1}')
  if [ ${Q_AVG_INT:-0} -ge 2 ] 2>/dev/null; then
    Q_BADGE="<span class='table-badge badge-red'>Critico</span>"
  elif [ ${Q_AVG_INT:-0} -ge 1 ] 2>/dev/null; then
    Q_BADGE="<span class='table-badge badge-yellow'>Atencao</span>"
  else
    Q_BADGE="<span class='table-badge badge-blue'>OK</span>"
  fi
  QUERY_ROWS="${QUERY_ROWS}<tr>
    <td style='color:#f0f4f8;font-weight:600'>${QIDX}</td>
    <td class='mono' style='color:#f59e0b;font-size:11px'>${q_text}</td>
    <td>${q_count}</td>
    <td style='font-weight:600'>${q_avg}s</td>
    <td class='mono'>${q_rows}</td>
    <td>${Q_BADGE}</td>
  </tr>"
  QIDX=$((QIDX + 1))
done <<< "${TOP_QUERIES}"

if [ -z "${QUERY_ROWS}" ]; then
  QUERY_ROWS="<tr><td colspan='6' style='text-align:center;color:#556677;padding:20px'>Nenhuma query capturada pelo Performance Schema</td></tr>"
fi

# --- Fragmentacao ---
FRAG_ROWS=""
while IFS=$'\t' read -r f_schema f_table f_total f_frag f_pct; do
  [ -z "${f_schema}" ] && continue
  FRAG_ROWS="${FRAG_ROWS}<tr>
    <td style='color:#f0f4f8;font-weight:500'>${f_schema}</td>
    <td class='mono'>${f_table}</td>
    <td>${f_total} MB</td>
    <td style='color:#f59e0b'>${f_frag} MB</td>
    <td style='color:#f59e0b;font-weight:600'>${f_pct}%</td>
  </tr>"
done <<< "${FRAG_TABLES}"

if [ -z "${FRAG_ROWS}" ]; then
  FRAG_ROWS="<tr><td colspan='5' style='text-align:center;color:#10b981;padding:20px'>&#10003; Nenhuma tabela com fragmentacao significativa</td></tr>"
fi

# --- Replicacao HTML ---
if [ "${HAS_REPLICA}" = "YES" ]; then
  IO_COLOR=$( [ "${REPLICA_IO}" = "Yes" ] && echo "#10b981" || echo "#ef4444" )
  SQL_COLOR=$( [ "${REPLICA_SQL}" = "Yes" ] && echo "#10b981" || echo "#ef4444" )
  IO_ICON=$( [ "${REPLICA_IO}" = "Yes" ] && echo "&#10003;" || echo "&#10007;" )
  SQL_ICON=$( [ "${REPLICA_SQL}" = "Yes" ] && echo "&#10003;" || echo "&#10007;" )
  LAG_COLOR=$( [ ${REPLICA_LAG:-0} -le 5 ] 2>/dev/null && echo "#10b981" || echo "#f59e0b" )
  REPLICA_HTML="<div class='card'>
    <div class='card-header'>
      <span class='card-title'>Replicacao</span>
      <div class='card-icon' style='background:rgba(6,182,212,0.1)'>&#128260;</div>
    </div>
    <div class='card-detail' style='margin-top:8px'>
      <div style='display:flex;justify-content:space-between;padding:6px 0;border-bottom:1px solid #1e2d3d'>
        <span>Replica IO Thread</span><span style='color:${IO_COLOR};font-weight:500'>${REPLICA_IO} ${IO_ICON}</span>
      </div>
      <div style='display:flex;justify-content:space-between;padding:6px 0;border-bottom:1px solid #1e2d3d'>
        <span>Replica SQL Thread</span><span style='color:${SQL_COLOR};font-weight:500'>${REPLICA_SQL} ${SQL_ICON}</span>
      </div>
      <div style='display:flex;justify-content:space-between;padding:6px 0'>
        <span>Lag (Seconds Behind)</span><span style='color:${LAG_COLOR};font-weight:500'>${REPLICA_LAG:-0} seg</span>
      </div>
    </div>
  </div>"
else
  REPLICA_HTML="<div class='card'>
    <div class='card-header'>
      <span class='card-title'>Replicacao</span>
      <div class='card-icon' style='background:rgba(85,102,119,0.1)'>&#128260;</div>
    </div>
    <div class='card-value' style='font-size:22px;color:#556677'>NAO CONFIGURADA</div>
    <div class='card-detail'>Ambiente standalone (sem replica)</div>
  </div>"
fi

# ============================================================
# GERAR HTML
# ============================================================
cat > "${HTML_FILE}" << HTMLEOF
<!DOCTYPE html>
<html lang="pt-BR">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>MySQL Health Check - ${HOSTNAME_SERVER}</title>
<style>
  :root {
    --bg-primary: #0a0e17; --bg-card: #111827; --bg-card-hover: #1a2332;
    --border: #1e2d3d; --text-primary: #f0f4f8; --text-secondary: #8899aa; --text-muted: #556677;
    --accent-blue: #3b82f6; --accent-cyan: #06b6d4; --accent-green: #10b981;
    --accent-yellow: #f59e0b; --accent-red: #ef4444; --accent-orange: #f97316;
  }
  * { margin: 0; padding: 0; box-sizing: border-box; }
  body { font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; background: var(--bg-primary); color: var(--text-primary); min-height: 100vh; line-height: 1.6; }
  .container { max-width: 1200px; margin: 0 auto; padding: 24px; }
  .header { display: flex; align-items: center; justify-content: space-between; padding: 28px 36px; background: var(--bg-card); border: 1px solid var(--border); border-radius: 16px; margin-bottom: 24px; position: relative; overflow: hidden; }
  .header::before { content: ''; position: absolute; top: 0; left: 0; right: 0; height: 3px; background: linear-gradient(90deg, #e31937 0%, #e31937 50%, #00758f 50%, #00758f 100%); }
  .header-center { text-align: center; flex: 1; }
  .header-center h1 { font-size: 22px; font-weight: 700; letter-spacing: 1px; color: #f0f4f8; }
  .header-center .subtitle { font-size: 13px; color: var(--text-muted); margin-top: 4px; }
  .logo-mysql { display: flex; align-items: center; gap: 8px; padding: 8px 16px; background: linear-gradient(135deg, #00758f, #00a4c4); border-radius: 10px; font-weight: 700; font-size: 16px; color: white; }
  .status-banner { display: flex; align-items: center; justify-content: center; gap: 12px; padding: 16px; background: ${OVERALL_BG}; border: 1px solid ${OVERALL_BORDER}; border-radius: 12px; margin-bottom: 24px; flex-wrap: wrap; }
  .status-dot { width: 12px; height: 12px; border-radius: 50%; background: ${OVERALL_COLOR}; }
  .status-text { font-weight: 600; font-size: 15px; color: ${OVERALL_COLOR}; }
  .status-date { color: var(--text-muted); font-size: 13px; }
  .grid-4 { display: grid; grid-template-columns: repeat(4, 1fr); gap: 16px; margin-bottom: 24px; }
  .grid-3 { display: grid; grid-template-columns: repeat(3, 1fr); gap: 16px; margin-bottom: 24px; }
  .grid-2 { display: grid; grid-template-columns: repeat(2, 1fr); gap: 16px; margin-bottom: 24px; }
  .card { background: var(--bg-card); border: 1px solid var(--border); border-radius: 14px; padding: 24px; }
  .card-header { display: flex; align-items: center; justify-content: space-between; margin-bottom: 16px; }
  .card-title { font-size: 12px; font-weight: 600; text-transform: uppercase; letter-spacing: 1.5px; color: var(--text-muted); }
  .card-icon { width: 36px; height: 36px; border-radius: 10px; display: flex; align-items: center; justify-content: center; font-size: 18px; }
  .card-value { font-size: 36px; font-weight: 700; line-height: 1.1; margin-bottom: 6px; }
  .card-detail { font-size: 13px; color: var(--text-secondary); }
  .progress-container { margin-top: 12px; }
  .progress-header { display: flex; justify-content: space-between; margin-bottom: 6px; font-size: 13px; }
  .progress-label { color: var(--text-secondary); }
  .progress-value { color: var(--text-primary); font-weight: 600; }
  .progress-bar { height: 8px; background: rgba(255,255,255,0.05); border-radius: 4px; overflow: hidden; }
  .progress-fill { height: 100%; border-radius: 4px; }
  .progress-fill.green { background: linear-gradient(135deg, #10b981, #34d399); }
  .progress-fill.blue { background: linear-gradient(135deg, #3b82f6, #06b6d4); }
  .progress-fill.yellow { background: linear-gradient(135deg, #f59e0b, #fbbf24); }
  .progress-fill.red { background: linear-gradient(135deg, #ef4444, #f87171); }
  .table-card { background: var(--bg-card); border: 1px solid var(--border); border-radius: 14px; overflow: hidden; margin-bottom: 24px; }
  .table-card-header { padding: 20px 24px; border-bottom: 1px solid var(--border); display: flex; align-items: center; justify-content: space-between; }
  .table-card-title { font-size: 16px; font-weight: 600; }
  .table-badge { font-size: 11px; font-weight: 600; padding: 4px 10px; border-radius: 20px; }
  .badge-green { background: rgba(16,185,129,0.15); color: #10b981; }
  .badge-yellow { background: rgba(245,158,11,0.15); color: #f59e0b; }
  .badge-red { background: rgba(239,68,68,0.15); color: #ef4444; }
  .badge-blue { background: rgba(59,130,246,0.15); color: #3b82f6; }
  table { width: 100%; border-collapse: collapse; }
  th { padding: 12px 24px; font-size: 11px; font-weight: 600; text-transform: uppercase; letter-spacing: 1px; color: var(--text-muted); text-align: left; background: rgba(255,255,255,0.02); border-bottom: 1px solid var(--border); }
  td { padding: 14px 24px; font-size: 14px; color: var(--text-secondary); border-bottom: 1px solid rgba(255,255,255,0.03); }
  td.mono { font-family: 'Courier New', monospace; font-size: 13px; }
  .section-title { font-size: 11px; font-weight: 600; text-transform: uppercase; letter-spacing: 2px; color: var(--text-muted); margin-bottom: 16px; padding-left: 4px; }
  .alert-strip { display: flex; align-items: center; gap: 10px; padding: 14px 20px; border-radius: 10px; font-size: 13px; font-weight: 500; margin-bottom: 16px; }
  .alert-strip.info { background: rgba(59,130,246,0.08); border: 1px solid rgba(59,130,246,0.2); color: #3b82f6; }
  .alert-strip.warning { background: rgba(245,158,11,0.08); border: 1px solid rgba(245,158,11,0.2); color: #f59e0b; }
  .alert-strip.critical { background: rgba(239,68,68,0.08); border: 1px solid rgba(239,68,68,0.2); color: #ef4444; }
  .footer { text-align: center; padding: 24px; color: var(--text-muted); font-size: 12px; border-top: 1px solid var(--border); margin-top: 8px; }
  @media (max-width: 900px) { .grid-4, .grid-3 { grid-template-columns: repeat(2, 1fr); } .grid-2 { grid-template-columns: 1fr; } .header { flex-direction: column; gap: 16px; text-align: center; } }
</style>
</head>
<body>
<div class="container">

  <!-- HEADER -->
  <div class="header">
    <div class="header-center">
      <h1>MYSQL HEALTH CHECK</h1>
      <div class="subtitle">Daily Report &mdash; Database Administration</div>
    </div>
    <div><div class="logo-mysql"><span style="font-size:22px">&#128044;</span> MySQL</div></div>
  </div>

  <!-- STATUS -->
  <div class="status-banner">
    <div class="status-dot"></div>
    <span class="status-text">${OVERALL_STATUS}</span>
    <span class="status-date">${DATA_HOJE} &bull; ${HORA_HOJE} BRT &bull; Servidor: ${HOSTNAME_SERVER} &bull; MySQL ${MYSQL_VERSION}</span>
  </div>

  <!-- ALERTAS -->
  ${ALERT_MESSAGES}

  <!-- KPIs -->
  <div class="section-title">Indicadores Principais</div>
  <div class="grid-4">
    <div class="card">
      <div class="card-header"><span class="card-title">Uptime</span><div class="card-icon" style="background:rgba(16,185,129,0.1)">&#9201;</div></div>
      <div class="card-value" style="color:#10b981">${UPTIME_PCT}%</div>
      <div class="card-detail">${UPTIME_DAYS}d ${UPTIME_HOURS}h ${UPTIME_MINS}min desde ultimo restart</div>
    </div>
    <div class="card">
      <div class="card-header"><span class="card-title">Buffer Pool Hit Ratio</span><div class="card-icon" style="background:rgba(6,182,212,0.1)">&#127919;</div></div>
      <div class="card-value" style="color:#06b6d4">${BP_HIT_RATIO}%</div>
      <div class="card-detail">Target: &gt; 99% &bull; <span style="color:${OVERALL_COLOR}">${BP_STATUS}</span></div>
    </div>
    <div class="card">
      <div class="card-header"><span class="card-title">Conexoes</span><div class="card-icon" style="background:rgba(59,130,246,0.1)">&#128279;</div></div>
      <div class="card-value" style="color:#3b82f6">${THREADS_CONNECTED}</div>
      <div class="card-detail">de ${MAX_CONNECTIONS} max &bull; Pico: ${MAX_USED_CONN} &bull; ${CONN_PCT}% uso</div>
    </div>
    <div class="card">
      <div class="card-header"><span class="card-title">Queries/Segundo</span><div class="card-icon" style="background:rgba(249,115,22,0.1)">&#9889;</div></div>
      <div class="card-value" style="color:#f97316">${QPS}</div>
      <div class="card-detail">Total questions: ${QUESTIONS}</div>
    </div>
  </div>

  <!-- CAPACITY -->
  <div class="section-title">Capacity Planning</div>
  <div class="grid-3">
    <div class="card">
      <div class="card-header"><span class="card-title">Disco - ${MYSQL_DATADIR}</span><div class="card-icon" style="background:rgba(59,130,246,0.1)">&#128190;</div></div>
      <div class="card-value" style="color:#3b82f6">${DISK_PCT}%</div>
      <div class="card-detail">${DISK_USED} GB usado de ${DISK_TOTAL} GB (${DISK_AVAIL} GB livre)</div>
      <div class="progress-container">
        <div class="progress-header"><span class="progress-label">Uso atual</span><span class="progress-value">${DISK_USED} / ${DISK_TOTAL} GB</span></div>
        <div class="progress-bar"><div class="progress-fill ${DISK_BAR_COLOR}" style="width:${DISK_PCT}%"></div></div>
      </div>
    </div>
    <div class="card">
      <div class="card-header"><span class="card-title">Buffer Pool</span><div class="card-icon" style="background:rgba(16,185,129,0.1)">&#129504;</div></div>
      <div class="card-value" style="color:#10b981">${BUFFER_POOL_SIZE_GB} GB</div>
      <div class="card-detail">innodb_buffer_pool_size</div>
      <div class="progress-container">
        <div class="progress-header"><span class="progress-label">Hit Ratio</span><span class="progress-value">${BP_HIT_RATIO}%</span></div>
        <div class="progress-bar"><div class="progress-fill ${BP_COLOR}" style="width:${BP_HIT_RATIO}%"></div></div>
      </div>
    </div>
    <div class="card">
      <div class="card-header"><span class="card-title">Configuracao</span><div class="card-icon" style="background:rgba(249,115,22,0.1)">&#9881;</div></div>
      <div class="card-detail" style="margin-top:8px">
        <div style="display:flex;justify-content:space-between;padding:6px 0;border-bottom:1px solid #1e2d3d"><span>max_connections</span><span style="color:#f0f4f8;font-weight:500">${MAX_CONNECTIONS}</span></div>
        <div style="display:flex;justify-content:space-between;padding:6px 0;border-bottom:1px solid #1e2d3d"><span>innodb_log_file_size</span><span style="color:#f0f4f8">${LOG_FILE_SIZE} MB</span></div>
        <div style="display:flex;justify-content:space-between;padding:6px 0;border-bottom:1px solid #1e2d3d"><span>flush_log_at_trx_commit</span><span style="color:#f0f4f8">${FLUSH_COMMIT}</span></div>
        <div style="display:flex;justify-content:space-between;padding:6px 0;border-bottom:1px solid #1e2d3d"><span>slow_query_log</span><span style="color:$( [ "${SLOW_QUERY_LOG}" = "1" ] && echo "#10b981" || echo "#f59e0b" )">${SLOW_QUERY_LOG}</span></div>
        <div style="display:flex;justify-content:space-between;padding:6px 0;border-bottom:1px solid #1e2d3d"><span>performance_schema</span><span style="color:$( [ "${PERF_SCHEMA}" = "1" ] && echo "#10b981" || echo "#f59e0b" )">${PERF_SCHEMA}</span></div>
        <div style="display:flex;justify-content:space-between;padding:6px 0"><span>bind_address</span><span style="color:#f0f4f8">${BIND_ADDRESS}</span></div>
      </div>
    </div>
  </div>

  <!-- BACKUP & REPLICACAO -->
  <div class="section-title">Backup &amp; Replicacao</div>
  <div class="grid-2">
    <div class="card">
      <div class="card-header"><span class="card-title">Binary Logs</span><div class="card-icon" style="background:rgba(59,130,246,0.1)">&#128230;</div></div>
      <div class="card-detail" style="margin-top:8px">
        <div style="display:flex;justify-content:space-between;padding:6px 0;border-bottom:1px solid #1e2d3d"><span>Arquivos</span><span style="color:#f0f4f8;font-weight:500">${BINLOG_COUNT} binlogs</span></div>
        <div style="display:flex;justify-content:space-between;padding:6px 0"><span>Tamanho Total</span><span style="color:#f0f4f8">${BINLOG_SIZE} MB</span></div>
      </div>
    </div>
    ${REPLICA_HTML}
  </div>

  <!-- DATABASES -->
  <div class="table-card">
    <div class="table-card-header">
      <span class="table-card-title">Databases por Tamanho</span>
    </div>
    <table>
      <thead><tr><th>Database</th><th>Tamanho</th><th>Tabelas</th><th>Fragmentacao</th></tr></thead>
      <tbody>${DB_ROWS}</tbody>
    </table>
  </div>

  <!-- TOP QUERIES -->
  <div class="table-card">
    <div class="table-card-header">
      <span class="table-card-title">Top 5 Queries por Tempo Medio</span>
      <span class="table-badge badge-yellow">Slow Queries Total: ${SLOW_QUERIES}</span>
    </div>
    <table>
      <thead><tr><th>#</th><th>Query (resumo)</th><th>Execucoes</th><th>Tempo Medio</th><th>Rows Examined</th><th>Status</th></tr></thead>
      <tbody>${QUERY_ROWS}</tbody>
    </table>
  </div>

  <!-- FRAGMENTACAO -->
  <div class="table-card">
    <div class="table-card-header">
      <span class="table-card-title">Tabelas com Fragmentacao &gt; 10%</span>
      <span class="table-badge badge-blue">Tabelas sem PK: ${NO_PK_COUNT} &bull; MyISAM: ${MYISAM_COUNT}</span>
    </div>
    <table>
      <thead><tr><th>Schema</th><th>Tabela</th><th>Tamanho</th><th>Fragmentacao</th><th>% Frag</th></tr></thead>
      <tbody>${FRAG_ROWS}</tbody>
    </table>
  </div>

  <!-- INNODB METRICS -->
  <div class="section-title">Metricas InnoDB</div>
  <div class="grid-4">
    <div class="card" style="text-align:center">
      <div class="card-title" style="margin-bottom:12px">Reads/s</div>
      <div class="card-value" style="font-size:28px;color:#06b6d4">${READS_PER_SEC}</div>
    </div>
    <div class="card" style="text-align:center">
      <div class="card-title" style="margin-bottom:12px">Writes/s</div>
      <div class="card-value" style="font-size:28px;color:#f97316">${WRITES_PER_SEC}</div>
    </div>
    <div class="card" style="text-align:center">
      <div class="card-title" style="margin-bottom:12px">Row Lock Waits</div>
      <div class="card-value" style="font-size:28px;color:#10b981">${INNODB_ROW_LOCK_WAITS}</div>
    </div>
    <div class="card" style="text-align:center">
      <div class="card-title" style="margin-bottom:12px">Usuarios Ativos</div>
      <div class="card-value" style="font-size:28px;color:#3b82f6">${USER_COUNT}</div>
      <div class="card-detail">${SUPER_COUNT} com SUPER priv</div>
    </div>
  </div>

  <!-- FOOTER -->
  <div class="footer">
    Relatorio gerado automaticamente pelo <strong>MySQL Health Check System</strong> &bull; DBA Team &mdash;<br>
    Proxima coleta: ${DATA_AMANHA} 08:00 BRT &bull; Servidor: ${HOSTNAME_SERVER}
  </div>

</div>
</body>
</html>
HTMLEOF

# Criar link para latest
cp -f "${HTML_FILE}" "${HTML_LATEST}"

echo "[$(date)] HTML gerado: ${HTML_FILE}"

# ============================================================
# ENVIAR EMAIL
# ============================================================
echo "[$(date)] Enviando email..."

${SEND_EMAIL} \
  -f ${EMAIL_FROM} \
  ${EMAIL_TO} \
  -u "${EMAIL_SUBJECT}" \
  -o message-file=${HTML_FILE} \
  -o message-content-type=html \
  -o tls=no

if [ $? -eq 0 ]; then
  echo "[$(date)] Email enviado com sucesso!"
else
  echo "[$(date)] ERRO ao enviar email! (sendEmail pode nao estar configurado neste servidor)"
fi

# ============================================================
# LIMPEZA - Manter apenas ultimos 30 relatorios
# ============================================================
ls -t ${LOG_DIR}/mysql_healthcheck_2*.html 2>/dev/null | tail -n +31 | xargs rm -f 2>/dev/null

echo "[$(date)] Processo finalizado."
