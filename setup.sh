#!/bin/sh
# Script para configurar o banco de dados CentralServicos

# Definir cores para feedback visual
YELLOW="\033[33m"
GREEN="\033[32m"
RED="\033[31m"
RESET="\033[0m"

echo "${YELLOW}Iniciando configuração do banco de dados CentralServicos...${RESET}"

# URL do script SQL no seu repositório GitHub
SQL_FILE_URL="https://raw.githubusercontent.com/erildobarone/scripts-de-banco-de-dados-/main/postgres/centralservicos/create_db.sql"

# Verificar se curl está instalado, se não, tente instalá-lo
if ! command -v curl &> /dev/null; then
    echo "${YELLOW}curl não encontrado, tentando instalar...${RESET}"
    apt-get update && apt-get install -y curl
fi

# Baixar o script SQL
echo "${YELLOW}Baixando script SQL do GitHub...${RESET}"
curl -L $SQL_FILE_URL -o /tmp/create_db.sql

# Verificar se o download foi bem-sucedido
if [ ! -f /tmp/create_db.sql ]; then
    echo "${RED}Erro: Falha ao baixar o script SQL. Verifique a URL e a conexão.${RESET}"
    exit 1
fi

# Verificar se o banco já existe
if psql -U postgres -lqt | cut -d \| -f 1 | grep -qw centralservicos; then
    echo "${YELLOW}Banco de dados já existe. Deseja recriá-lo? (s/n)${RESET}"
    read -r resposta
    if [ "$resposta" = "s" ]; then
        echo "${YELLOW}Removendo banco de dados existente...${RESET}"
        psql -U postgres -c "DROP DATABASE centralservicos;"
    else
        echo "${GREEN}Operação cancelada.${RESET}"
        exit 0
    fi
fi

# Criar o banco de dados
echo "${YELLOW}Criando banco de dados centralservicos...${RESET}"
psql -U postgres -c "CREATE DATABASE centralservicos;"

# Executar o script SQL
echo "${YELLOW}Executando script SQL para criar estrutura do banco...${RESET}"
psql -U postgres -d centralservicos -f /tmp/create_db.sql

# Verificar tabelas criadas
echo "${YELLOW}Verificando tabelas criadas...${RESET}"
psql -U postgres -d centralservicos -c "
SELECT table_name 
FROM information_schema.tables 
WHERE table_schema = 'public' 
ORDER BY table_name;
"

# Verificar funções criadas
echo "${YELLOW}Verificando funções criadas...${RESET}"
psql -U postgres -d centralservicos -c "
SELECT routine_name 
FROM information_schema.routines 
WHERE routine_schema = 'public' 
ORDER BY routine_name;
"

echo "${GREEN}Banco de dados CentralServicos configurado com sucesso!${RESET}"
echo "${YELLOW}Script concluído. O banco de dados está pronto para uso pelo N8N.${RESET}"

# Limpar arquivo temporário
rm -f /tmp/create_db.sql