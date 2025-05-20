-- Tabela principal de atendimentos
CREATE TABLE atendimentos (
    id SERIAL PRIMARY KEY,
    session_id TEXT UNIQUE NOT NULL,
    departamento TEXT NOT NULL DEFAULT 'triagem',
    status TEXT NOT NULL DEFAULT 'novo',
    primeira_interacao TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    ultima_interacao TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    chamado_id INTEGER NULL,
    encerrado_em TIMESTAMP NULL,
    encerrado_por TEXT NULL,
    tempo_atendimento_segundos INTEGER NULL,
    
    -- Campos de informações do usuário
    nome_usuario TEXT NULL,
    email_usuario TEXT NULL,
    telefone_usuario TEXT NULL,
    setor_usuario TEXT NULL,
    
    -- Metadados adicionais
    origem TEXT NULL,
    prioridade TEXT NULL DEFAULT 'normal',
    feedback_score INTEGER NULL,
    feedback_comentario TEXT NULL
);

-- Tabela para histórico de mensagens
CREATE TABLE mensagens (
    id SERIAL PRIMARY KEY,
    atendimento_id INTEGER NOT NULL REFERENCES atendimentos(id),
    remetente TEXT NOT NULL,
    conteudo TEXT NOT NULL,
    timestamp TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    classificacao TEXT NULL,
    is_private BOOLEAN NOT NULL DEFAULT FALSE
);

-- Tabela para tickets GLPI
CREATE TABLE tickets (
    id SERIAL PRIMARY KEY,
    atendimento_id INTEGER NOT NULL REFERENCES atendimentos(id),
    glpi_ticket_id INTEGER NOT NULL,
    titulo TEXT NOT NULL,
    descricao TEXT NOT NULL,
    tipo INTEGER NOT NULL,
    categoria_id INTEGER NOT NULL,
    categoria_nome TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'aberto',
    criado_em TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    atualizado_em TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    prioridade INTEGER NOT NULL DEFAULT 3,
    usuario_id_glpi INTEGER NULL,
    tecnico_id_glpi INTEGER NULL,
    grupo_id_glpi INTEGER NULL
);

-- Tabela para categorias GLPI
CREATE TABLE categorias_glpi (
    id INTEGER PRIMARY KEY,
    nome TEXT NOT NULL,
    nome_completo TEXT NOT NULL,
    is_incident BOOLEAN NOT NULL DEFAULT TRUE,
    is_request BOOLEAN NOT NULL DEFAULT TRUE,
    is_helpdesk_visible BOOLEAN NOT NULL DEFAULT TRUE,
    ultima_atualizacao TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- Tabela para logs de operações
CREATE TABLE logs (
    id SERIAL PRIMARY KEY,
    atendimento_id INTEGER NULL REFERENCES atendimentos(id),
    tipo TEXT NOT NULL,
    acao TEXT NOT NULL,
    detalhes JSONB NULL,
    timestamp TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    ip_origem TEXT NULL,
    usuario_sistema TEXT NULL
);

-- Tabela para estatísticas de atendimento
CREATE TABLE estatisticas (
    id SERIAL PRIMARY KEY,
    data DATE NOT NULL DEFAULT CURRENT_DATE UNIQUE,
    total_atendimentos INTEGER NOT NULL DEFAULT 0,
    atendimentos_ti_infra INTEGER NOT NULL DEFAULT 0,
    atendimentos_ti_sistemas INTEGER NOT NULL DEFAULT 0,
    atendimentos_rh INTEGER NOT NULL DEFAULT 0,
    tickets_criados INTEGER NOT NULL DEFAULT 0,
    tempo_medio_atendimento INTEGER NOT NULL DEFAULT 0,
    indice_satisfacao NUMERIC(3,2) NULL
);

-- Tabela para configurações do sistema
CREATE TABLE configuracoes (
    chave TEXT PRIMARY KEY,
    valor TEXT NOT NULL,
    descricao TEXT NULL,
    alterado_em TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    alterado_por TEXT NULL
);

-- Tabela para histórico de chat (para integração com LangChain)
CREATE TABLE chat_histories (
    id SERIAL PRIMARY KEY,
    session_id TEXT NOT NULL,
    history JSONB NOT NULL DEFAULT '{"messages": []}'::jsonb,
    ultima_atualizacao TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- Índices para otimização de consultas
CREATE INDEX idx_atendimentos_session_id ON atendimentos(session_id);
CREATE INDEX idx_atendimentos_status ON atendimentos(status);
CREATE INDEX idx_atendimentos_departamento ON atendimentos(departamento);
CREATE INDEX idx_atendimentos_email ON atendimentos(email_usuario);
CREATE INDEX idx_mensagens_atendimento_id ON mensagens(atendimento_id);
CREATE INDEX idx_mensagens_timestamp ON mensagens(timestamp);
CREATE INDEX idx_tickets_atendimento_id ON tickets(atendimento_id);
CREATE INDEX idx_tickets_glpi_id ON tickets(glpi_ticket_id);
CREATE INDEX idx_logs_timestamp ON logs(timestamp);
CREATE INDEX idx_logs_tipo ON logs(tipo);
CREATE INDEX idx_chat_histories_session ON chat_histories(session_id);

-- Funções SQL úteis

-- Função para iniciar novo atendimento
CREATE OR REPLACE FUNCTION iniciar_atendimento(
    p_session_id TEXT,
    p_nome TEXT DEFAULT NULL,
    p_email TEXT DEFAULT NULL,
    p_telefone TEXT DEFAULT NULL,
    p_setor TEXT DEFAULT NULL
)
RETURNS TABLE (id INTEGER, session_id TEXT, status TEXT) AS $$
BEGIN
    RETURN QUERY
    INSERT INTO atendimentos (
        session_id, 
        nome_usuario, 
        email_usuario, 
        telefone_usuario, 
        setor_usuario
    )
    VALUES (
        p_session_id, 
        p_nome, 
        p_email, 
        p_telefone, 
        p_setor
    )
    ON CONFLICT (session_id) 
    DO UPDATE SET 
        ultima_interacao = CURRENT_TIMESTAMP, 
        status = 'ativo',
        nome_usuario = COALESCE(p_nome, atendimentos.nome_usuario),
        email_usuario = COALESCE(p_email, atendimentos.email_usuario),
        telefone_usuario = COALESCE(p_telefone, atendimentos.telefone_usuario),
        setor_usuario = COALESCE(p_setor, atendimentos.setor_usuario)
    WHERE atendimentos.status != 'encerrado'
    RETURNING atendimentos.id, atendimentos.session_id, atendimentos.status;
    
    -- Inicializar histórico de chat
    INSERT INTO chat_histories (session_id)
    VALUES (p_session_id)
    ON CONFLICT DO NOTHING;
END;
$$ LANGUAGE plpgsql;

-- Função para atualizar departamento
CREATE OR REPLACE FUNCTION atualizar_departamento(p_session_id TEXT, p_departamento TEXT)
RETURNS VOID AS $$
BEGIN
    UPDATE atendimentos 
    SET departamento = p_departamento, 
        ultima_interacao = CURRENT_TIMESTAMP
    WHERE session_id = p_session_id
      AND status != 'encerrado';
    
    INSERT INTO logs (atendimento_id, tipo, acao, detalhes)
    SELECT id, 'info', 'atualizacao_departamento', 
           jsonb_build_object('departamento', p_departamento)
    FROM atendimentos
    WHERE session_id = p_session_id;
END;
$$ LANGUAGE plpgsql;

-- Função para registrar mensagem
CREATE OR REPLACE FUNCTION registrar_mensagem(
    p_session_id TEXT, 
    p_remetente TEXT, 
    p_conteudo TEXT, 
    p_classificacao TEXT DEFAULT NULL
)
RETURNS INTEGER AS $$
DECLARE
    v_atendimento_id INTEGER;
    v_mensagem_id INTEGER;
BEGIN
    -- Obter ID do atendimento
    SELECT id INTO v_atendimento_id
    FROM atendimentos
    WHERE session_id = p_session_id;
    
    -- Se não encontrar, criar novo atendimento
    IF v_atendimento_id IS NULL THEN
        INSERT INTO atendimentos (session_id)
        VALUES (p_session_id)
        RETURNING id INTO v_atendimento_id;
    END IF;
    
    -- Inserir mensagem
    INSERT INTO mensagens (atendimento_id, remetente, conteudo, classificacao)
    VALUES (v_atendimento_id, p_remetente, p_conteudo, p_classificacao)
    RETURNING id INTO v_mensagem_id;
    
    -- Atualizar timestamp do atendimento
    UPDATE atendimentos 
    SET ultima_interacao = CURRENT_TIMESTAMP
    WHERE id = v_atendimento_id;
    
    -- Atualizar histórico de chat (para LangChain)
    UPDATE chat_histories
    SET history = jsonb_set(
        history,
        '{messages}',
        (history->'messages') || jsonb_build_object(
            'role', CASE WHEN p_remetente = 'usuario' THEN 'human' ELSE 'ai' END,
            'content', p_conteudo
        )
    ),
    ultima_atualizacao = CURRENT_TIMESTAMP
    WHERE session_id = p_session_id;
    
    RETURN v_mensagem_id;
END;
$$ LANGUAGE plpgsql;

-- Função para registrar ticket GLPI
CREATE OR REPLACE FUNCTION registrar_ticket(
    p_session_id TEXT, 
    p_glpi_ticket_id INTEGER, 
    p_titulo TEXT, 
    p_descricao TEXT,
    p_tipo INTEGER,
    p_categoria_id INTEGER,
    p_categoria_nome TEXT
)
RETURNS VOID AS $$
DECLARE
    v_atendimento_id INTEGER;
BEGIN
    -- Obter ID do atendimento
    SELECT id INTO v_atendimento_id
    FROM atendimentos
    WHERE session_id = p_session_id;
    
    -- Inserir ticket
    INSERT INTO tickets (
        atendimento_id, glpi_ticket_id, titulo, descricao, 
        tipo, categoria_id, categoria_nome
    ) VALUES (
        v_atendimento_id, p_glpi_ticket_id, p_titulo, p_descricao, 
        p_tipo, p_categoria_id, p_categoria_nome
    );
    
    -- Atualizar atendimento
    UPDATE atendimentos 
    SET chamado_id = p_glpi_ticket_id,
        status = 'com_chamado',
        ultima_interacao = CURRENT_TIMESTAMP
    WHERE session_id = p_session_id;
    
    -- Registrar log
    INSERT INTO logs (atendimento_id, tipo, acao, detalhes)
    VALUES (v_atendimento_id, 'info', 'criacao_ticket', 
            jsonb_build_object(
                'ticket_id', p_glpi_ticket_id,
                'titulo', p_titulo,
                'categoria', p_categoria_nome
            ));
END;
$$ LANGUAGE plpgsql;

-- Função para encerrar atendimento
CREATE OR REPLACE FUNCTION encerrar_atendimento(
    p_session_id TEXT, 
    p_encerrado_por TEXT DEFAULT 'sistema'
)
RETURNS VOID AS $$
BEGIN
    UPDATE atendimentos 
    SET status = 'encerrado',
        encerrado_em = CURRENT_TIMESTAMP,
        encerrado_por = p_encerrado_por,
        tempo_atendimento_segundos = EXTRACT(EPOCH FROM (CURRENT_TIMESTAMP - primeira_interacao))
    WHERE session_id = p_session_id
      AND status != 'encerrado';
    
    INSERT INTO logs (atendimento_id, tipo, acao, detalhes)
    SELECT id, 'info', 'encerramento', 
           jsonb_build_object('encerrado_por', p_encerrado_por)
    FROM atendimentos
    WHERE session_id = p_session_id;
END;
$$ LANGUAGE plpgsql;

-- Função para obter histórico de mensagens
CREATE OR REPLACE FUNCTION obter_historico_mensagens(p_session_id TEXT)
RETURNS TABLE(
    id INTEGER,
    timestamp TIMESTAMP,
    remetente TEXT,
    conteudo TEXT
) AS $$
BEGIN
    RETURN QUERY
    SELECT m.id, m.timestamp, m.remetente, m.conteudo
    FROM mensagens m
    JOIN atendimentos a ON m.atendimento_id = a.id
    WHERE a.session_id = p_session_id
    ORDER BY m.timestamp ASC;
END;
$$ LANGUAGE plpgsql;

-- Função para obter histórico de chat para LangChain
CREATE OR REPLACE FUNCTION obter_historico_chat(p_session_id TEXT)
RETURNS JSONB AS $$
DECLARE
    v_history JSONB;
BEGIN
    SELECT history INTO v_history
    FROM chat_histories
    WHERE session_id = p_session_id;
    
    IF v_history IS NULL THEN
        -- Criar novo histórico se não existir
        INSERT INTO chat_histories (session_id, history)
        VALUES (p_session_id, '{"messages": []}'::jsonb)
        RETURNING history INTO v_history;
    END IF;
    
    RETURN v_history;
END;
$$ LANGUAGE plpgsql;

-- Conceder permissões para o usuário n8n (se existir)
DO $$
BEGIN
    IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'n8n') THEN
        EXECUTE 'GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO n8n';
        EXECUTE 'GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO n8n';
        EXECUTE 'GRANT ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA public TO n8n';
    END IF;
END
$$;