# MySQL Health Check — Relatório automatizado com envio por e-mail

Script Bash que coleta métricas de saúde de um servidor MySQL, gera um relatório HTML visual e envia automaticamente por e-mail usando o **sendEmail** (Perl).

Criado para ambientes corporativos onde não é possível instalar ferramentas como `postfix`, `mailx` ou `sendmail`.

---

## Exemplo do relatório

O e-mail recebido renderiza um dashboard completo diretamente no cliente de e-mail:

<img width="907" height="905" alt="image" src="https://github.com/user-attachments/assets/ab3d34d7-088e-4b05-be0e-1c2d53ac1066" />


O relatório inclui:

- Status geral do servidor (Operational / Atenção / Crítico) com alertas dinâmicos
- KPIs: uptime, buffer pool hit ratio, conexões ativas, queries/segundo
- Capacity planning: uso de disco, buffer pool size, parâmetros de configuração
- Binary logs e status de replicação
- Databases por tamanho com fragmentação
- Top 5 queries por tempo médio (via Performance Schema)
- Tabelas com fragmentação acima de 10%
- Métricas InnoDB: reads/s, writes/s, row lock waits
- Contagem de usuários e privilégios

---

## Estrutura do projeto

```
mysql-healthcheck/
├── health_mysql.sh                  # Script principal: coleta + HTML + envio
├── sendEmail                        # Cliente SMTP standalone (Perl) — ver instruções abaixo
├── logs/                            # Relatórios HTML gerados (criado automaticamente)
│   ├── mysql_healthcheck_YYYYMMDD_HHMMSS.html
│   └── mysql_healthcheck_latest.html
├── docs/
│   └── exemplo_relatorio.html       # Exemplo real de relatório gerado
└── README.md
```

---

## Pré-requisitos

- **Linux** (testado em RHEL 9, funciona em qualquer distribuição)
- **Perl** (já presente na maioria das instalações Linux)
- **MySQL client** (`mysql` CLI disponível no PATH)
- Acesso a um **servidor SMTP** para envio (relay corporativo ou externo)

Não é necessário instalar nenhum pacote adicional.

---

## Onde baixar o sendEmail

O sendEmail é um script Perl standalone criado por Brandon Zehm. **Não precisa instalar nada** — é um único arquivo que você copia pro servidor e usa.

Repositório oficial:

> **https://github.com/zehm/sendEmail**

Para baixar e deixar pronto pra uso:

```bash
# Clonar o repositório
git clone https://github.com/zehm/sendEmail.git

# Ou baixar direto o script (só precisa desse arquivo)
curl -o sendEmail https://raw.githubusercontent.com/zehm/sendEmail/master/sendEmail

# Dar permissão de execução
chmod +x sendEmail

# Testar
perl sendEmail -h
```

Se o servidor não tem acesso à internet (comum em ambientes corporativos), basta baixar o arquivo `sendEmail` em outra máquina e copiar via `scp`:

```bash
scp sendEmail usuario@servidor-destino:/home/mysqlemail/sendEmail
```

Funciona em qualquer Linux com Perl: RHEL, CentOS, Oracle Linux, Ubuntu, Debian, etc.

---

## Configuração

### 1. Editar as variáveis de conexão MySQL

No início do `health_mysql.sh`, ajuste:

```bash
MYSQL_USER="seu_usuario"
MYSQL_PASS='sua_senha'
MYSQL_HOST="localhost"
MYSQL_PORT="3306"
```

### 2. Configurar os destinatários de e-mail

```bash
SEND_EMAIL="/usr/bin/perl /caminho/para/sendEmail"
EMAIL_FROM="dba-mysql@suaempresa.com.br"
EMAIL_TO="-t destinatario1@empresa.com.br \
-t destinatario2@empresa.com.br"
```

### 3. Ajustar o path do sendEmail

Coloque o arquivo `sendEmail` no mesmo diretório do script (ou em outro local acessível) e atualize a variável `SEND_EMAIL` com o caminho completo:

```bash
SEND_EMAIL="/usr/bin/perl /home/mysqlemail/sendEmail"
```

### 4. Permissões

```bash
chmod +x health_mysql.sh
chmod +x sendEmail
```

---

## Uso

### Execução manual

```bash
./health_mysql.sh
```

### Agendamento via cron (diário às 08:00)

```bash
crontab -e
```

```
0 8 * * * /home/mysqlemail/mysql-healthcheck/health_mysql.sh >> /home/mysqlemail/mysql-healthcheck/logs/healthcheck_cron.log 2>&1
```

---

## O que o script coleta

### Variáveis e status do MySQL

| Métrica | Fonte |
|---|---|
| Versão, hostname, datadir | `SELECT @@version`, `@@hostname`, `@@datadir` |
| Buffer pool size | `SELECT @@innodb_buffer_pool_size` |
| Max connections | `SELECT @@max_connections` |
| Uptime | `SHOW STATUS LIKE 'Uptime'` |
| Threads connected/running | `SHOW STATUS LIKE 'Threads_connected'` |
| Buffer pool hit ratio | `Innodb_buffer_pool_reads` / `Innodb_buffer_pool_read_requests` |
| Queries por segundo | `Questions` / `Uptime` |
| InnoDB rows read/inserted/updated/deleted | `SHOW STATUS LIKE 'Innodb_rows_%'` |
| Row lock waits | `SHOW STATUS LIKE 'Innodb_row_lock_waits'` |
| Slow queries | `SHOW STATUS LIKE 'Slow_queries'` |

### Queries no information_schema e performance_schema

O script consulta diretamente o `information_schema` e `performance_schema` para coletar dados sobre databases, fragmentação, tabelas sem PK, tabelas MyISAM e top queries por tempo médio. Consulte o código em `health_mysql.sh` para ver todas as queries utilizadas.

### Dados do sistema operacional

- Uso de disco do datadir via `df`

---

## Alertas automáticos

O relatório gera alertas condicionais baseados nas métricas coletadas:

| Condição | Nível | Alerta |
|---|---|---|
| Disco ≥ 90% | Crítico | Risco iminente de indisponibilidade |
| Disco ≥ 80% | Atenção | Planejar expansão |
| Disco ≥ 70% | Info | Monitorar crescimento |
| Buffer pool hit ratio < 95% | Atenção | Avaliar aumento do innodb_buffer_pool_size |
| Tabelas sem PK > 0 | Info | Best practice |
| Tabelas MyISAM > 0 | Atenção | Candidatas a migração para InnoDB |
| Replicação IO/SQL parada | Crítico | Replicação com problemas |
| Lag de replicação > 60s | Atenção | Lag detectado |

O status geral do servidor (`OPERATIONAL` / `ATENCAO` / `CRITICO`) é determinado automaticamente pela condição mais grave encontrada.

---

## Parâmetros do sendEmail utilizados

| Parâmetro | Descrição |
|---|---|
| `-f` | Endereço do remetente |
| `-t` | Endereço do destinatário (pode repetir para múltiplos) |
| `-u` | Assunto do e-mail |
| `-o message-file` | Arquivo com o corpo do e-mail |
| `-o message-content-type` | Tipo do conteúdo (`html` para HTML renderizado) |
| `-o tls` | Ativar/desativar TLS (`yes` / `no`) |

---

## Limpeza automática

O script mantém apenas os **30 relatórios mais recentes** no diretório `logs/`, removendo automaticamente os mais antigos a cada execução.

---

## Adaptação para outros bancos

A estrutura deste projeto pode ser adaptada para Oracle, PostgreSQL, SQL Server ou qualquer outro banco. O fluxo é o mesmo: script coleta métricas → gera HTML → sendEmail envia. Basta trocar as queries de coleta.

---

## Autor

**Gustavo** — Database Administrator  
[github.com/guborges](https://github.com/guborges)

---

## Licença

Este projeto é disponibilizado para uso livre. Use, adapte e compartilhe.
