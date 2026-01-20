-- 1. Creación de la base de datos
CREATE DATABASE centro_fp
    WITH 
    OWNER = admin
    ENCODING = 'UTF8'
    LC_COLLATE = 'es_ES.UTF-8'
    LC_CTYPE = 'es_ES.UTF-8'
    TEMPLATE = template0;

------------------------------------------

-- 2. Tipos de datos personalizados
-- 2.1 Tipos compuestos

-- Tipo para información de contacto
CREATE TYPE contacto_info AS (
    telefono_movil VARCHAR(20),
    telefono_fijo VARCHAR(20),
    email_personal VARCHAR(100),
    email_corporativo VARCHAR(100)
);

-- Tipo para dirección
CREATE TYPE direccion_completa AS (
    via VARCHAR(100),
    numero INTEGER,
    piso VARCHAR(10),
    puerta VARCHAR(10),
    codigo_postal VARCHAR(10),
    localidad VARCHAR(100),
    provincia VARCHAR(50),
    pais VARCHAR(50)
);

-- Tipo para calificación
CREATE TYPE nota_detalle AS (
    evaluacion VARCHAR(20),
    nota DECIMAL(4,2),
    fecha DATE,
    observaciones TEXT
);

-- 2.2 Tipos enumerados (ENUM)

-- Enums
CREATE TYPE tipo_modulo AS ENUM ('obligatoria', 'optativa', 'proyecto');
CREATE TYPE estado_matricula AS ENUM ('activa', 'aprobada', 'suspendida', 'no_presentado', 'convalidada');
CREATE TYPE turno_formacion AS ENUM ('mañana', 'tarde', 'noche');

------------------------------------------

-- 3. Modelo con herencia (BDOR)
-- 3.1 Tabla padre: persona

CREATE TABLE persona (
    id SERIAL PRIMARY KEY,
    dni VARCHAR(20) UNIQUE NOT NULL,
    nombre VARCHAR(100) NOT NULL,
    apellido1 VARCHAR(100) NOT NULL,
    apellido2 VARCHAR(100) NULL,
    fecha_nacimiento DATE NOT NULL,
    
    -- Tipo compuesto
    direccion direccion_completa,
    contacto contacto_info,
    
    -- Metadata en JSON
    datos_adicionales JSONB,
    
    fecha_registro TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    activo BOOLEAN DEFAULT true
);

-- 3.2 Tablas heredadas

-- alumno hereda de Persona
CREATE TABLE alumno (
    num_expediente VARCHAR(20) UNIQUE NOT NULL,
    fecha_matriculacion DATE NOT NULL,
    
    -- Arrays
    idiomas VARCHAR(50)[],
    intereses VARCHAR(100)[],
    
    -- JSONB para información académica flexible
    historial JSONB,
    
    -- Campos adicionales
    media_global DECIMAL(4,2),
    creditos_superados INTEGER DEFAULT 0,
    creditos_matriculados INTEGER DEFAULT 0
) INHERITS (persona);

-- Profesor hereda de Persona
CREATE TABLE profesor (
    num_empleado VARCHAR(20) UNIQUE NOT NULL,
    fecha_contratacion DATE NOT NULL,
    departamento VARCHAR(100),
    
    -- Arrays
    especialidades VARCHAR(100)[],
    titulaciones VARCHAR(200)[],
    
    -- JSONB 
    perfil_docente JSONB,
    
    -- Campos específicos
    horas_lectivas INTEGER,
    tutor_grupo BOOLEAN DEFAULT false
) INHERITS (persona);

-- Personal administrativo hereda de Persona
CREATE TABLE administrativo (
    num_empleado VARCHAR(20) UNIQUE NOT NULL,
    fecha_contratacion DATE NOT NULL,
    puesto VARCHAR(100),
    
    -- Arrays de permisos/roles
    permisos_sistema VARCHAR(50)[],
    
    nivel_acceso INTEGER DEFAULT 1
) INHERITS (persona);

-- 4. Ciclos formativos y módulos
-- 4.1 Tabla ciclo

CREATE TABLE ciclo (
    id SERIAL PRIMARY KEY,
    codigo VARCHAR(20) UNIQUE NOT NULL,
    nombre VARCHAR(200) NOT NULL,
    turno turno_formacion NOT NULL,
    
    -- JSONB 
    plan_formativo JSONB,
    
    duracion_años INTEGER NOT NULL,
    
    -- Array de salidas profesionales
    salidas_profesionales TEXT[],
    
    activa BOOLEAN DEFAULT true
);

CREATE TABLE modulo (
    id SERIAL PRIMARY KEY,
    codigo VARCHAR(20) UNIQUE NOT NULL,
    nombre VARCHAR(200) NOT NULL,
    carrera_id INTEGER REFERENCES ciclo(id),
    
    creditos INTEGER NOT NULL,
    curso INTEGER NOT NULL CHECK (curso BETWEEN 1 AND 2),
    tipo tipo_modulo DEFAULT 'obligatoria',
    
    -- Array de conocimientos previos
    conocimientos_previos VARCHAR(200)[],
    
    -- JSONB para temario y recursos
    contenido JSONB,
    
    max_alumnos INTEGER
);

ALTER TABLE profesor
  ADD CONSTRAINT profesor_pkey PRIMARY KEY (id);
ALTER TABLE alumno     
  ADD CONSTRAINT alumno_pkey PRIMARY KEY (id);
ALTER TABLE administrativo 
  ADD CONSTRAINT administrativo_pkey PRIMARY KEY (id);

------------------------------------------

-- 5. Relación profesor-asignatura
CREATE TABLE profesor_modulo (
    id SERIAL PRIMARY KEY,
    profesor_id INTEGER REFERENCES profesor(id),
    modulo_id INTEGER REFERENCES modulo(id),
    curso_academico VARCHAR(9) NOT NULL,
    grupo VARCHAR(10),
    horario JSONB,
    UNIQUE(profesor_id, modulo_id, curso_academico, grupo)
);

------------------------------------------

-- 6. Matrícula y evaluación

CREATE TABLE matricula (
    id SERIAL PRIMARY KEY,
    alumno_id INTEGER REFERENCES alumno(id),
    modulo_id INTEGER REFERENCES modulo(id),
    curso_academico VARCHAR(9) NOT NULL,
    
    -- Estado de la matrícula
    estado estado_matricula DEFAULT 'activa',
        
    -- Nota final
    nota_final DECIMAL(4,2),
    
    detalle_nota nota_detalle NOT NULL,

    -- JSONB para información adicional
    adaptaciones JSONB,
    
    UNIQUE(alumno_id, modulo_id, curso_academico)
);

------------------------------------------

-- 7. Funciones obligatorias (PL/pgSQL)

-- calcular_media_alumno(alumno_id)
CREATE OR REPLACE FUNCTION calcular_media_alumno(alumno_id_param INTEGER)
RETURNS DECIMAL(4,2) AS $$
DECLARE
    media DECIMAL(4,2);
BEGIN
    SELECT AVG(nota_final)
    INTO media
    FROM matricula
    WHERE alumno_id = alumno_id_param
      AND nota_final IS NOT NULL
      AND estado = 'aprobada';

    RETURN COALESCE(media,0);
END;
$$ LANGUAGE plpgsql;

-- creditos_superados(alumno_id)
CREATE OR REPLACE FUNCTION creditos_superados(alumno_id_param INTEGER)
RETURNS INTEGER AS $$
DECLARE
    total INTEGER;
BEGIN
    SELECT COALESCE(SUM(m.creditos),0)
    INTO total
    FROM matricula ma
    JOIN modulo m ON ma.modulo_id = m.id
    WHERE ma.alumno_id = alumno_id_param
      AND ma.estado = 'aprobada';

    RETURN total;
END;
$$ LANGUAGE plpgsql;

-- validar_curso_academico(texto)
CREATE OR REPLACE FUNCTION validar_curso_academico(texto VARCHAR)
RETURNS BOOLEAN AS $$
BEGIN
    RETURN texto ~ '^[0-9]{4}-[0-9]{4}$';
END;
$$ LANGUAGE plpgsql;

------------------------------------------

-- 8. TRIGGERS OBLIGATORIOS

-- Trigger trg_actualizar_media
CREATE OR REPLACE FUNCTION fn_actualizar_media()
RETURNS TRIGGER AS $$
BEGIN
    -- Solo recalcula si cambian nota_final o estado
    IF TG_OP = 'INSERT' OR 
       (OLD.nota_final IS DISTINCT FROM NEW.nota_final OR
        OLD.estado IS DISTINCT FROM NEW.estado) THEN
        
        UPDATE alumno
        SET media_global = calcular_media_alumno(NEW.alumno_id)
        WHERE id = NEW.alumno_id;
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_actualizar_media
AFTER INSERT OR UPDATE ON matricula
FOR EACH ROW
EXECUTE FUNCTION fn_actualizar_media();

-- Trigger trg_actualizar_creditos
CREATE OR REPLACE FUNCTION fn_actualizar_creditos()
RETURNS TRIGGER AS $$
DECLARE
    alumno_obj INTEGER;
BEGIN
    IF TG_OP = 'DELETE' THEN
        alumno_obj := OLD.alumno_id;
    ELSE
        alumno_obj := NEW.alumno_id;
    END IF;

    UPDATE alumno
    SET 
        creditos_superados   = creditos_superados(alumno_obj),
        creditos_matriculados = (
            SELECT COALESCE(SUM(m.creditos),0)
            FROM matricula ma
            JOIN modulo m ON ma.modulo_id = m.id
            WHERE ma.alumno_id = alumno_obj
        )
    WHERE id = alumno_obj;

    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_actualizar_creditos
AFTER INSERT OR UPDATE OR DELETE ON matricula
FOR EACH ROW
EXECUTE FUNCTION fn_actualizar_creditos();

-- Trigger trg_control_max_alumnos
CREATE OR REPLACE FUNCTION fn_control_max_alumnos()
RETURNS TRIGGER AS $$
DECLARE
    inscritos INTEGER;
    maximo INTEGER;
BEGIN
    SELECT COUNT(*) 
    INTO inscritos
    FROM matricula
    WHERE modulo_id = NEW.modulo_id
      AND curso_academico = NEW.curso_academico;

    SELECT max_alumnos
    INTO maximo
    FROM modulo
    WHERE id = NEW.modulo_id;

    IF maximo IS NOT NULL AND inscritos >= maximo THEN
        RAISE EXCEPTION 'No se pueden matricular más alumnos en este módulo (%).', NEW.modulo_id;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_control_max_alumnos
BEFORE INSERT ON matricula
FOR EACH ROW
EXECUTE FUNCTION fn_control_max_alumnos();

------------------------------------------

-- 9. VISTAS OBLIGATORIAS

-- vw_alumnos_resumen
CREATE OR REPLACE VIEW vw_alumnos_resumen AS
SELECT
    a.id,
    p.dni,
    p.nombre,
    p.apellido1 || ' ' || COALESCE(p.apellido2,'') AS apellidos,
    a.media_global,
    a.creditos_superados,
    a.creditos_matriculados,
    a.idiomas,
    (p.direccion).localidad AS localidad
FROM alumno a
JOIN persona p ON a.id = p.id;

-- vw_docencia
CREATE OR REPLACE VIEW vw_docencia AS
SELECT
    pm.curso_academico,
    p.nombre || ' ' || p.apellido1 || ' ' || COALESCE(p.apellido2,'') AS profesor,
    m.nombre AS modulo,
    c.nombre AS ciclo,
    pm.grupo,
    pm.horario
FROM profesor_modulo pm
JOIN profesor pr ON pm.profesor_id = pr.id
JOIN persona p ON pr.id = p.id
JOIN modulo m ON pm.modulo_id = m.id
JOIN ciclo c ON m.carrera_id = c.id;

-- vw_matriculas_detalle
CREATE OR REPLACE VIEW vw_matriculas_detalle AS
SELECT
    p.nombre || ' ' || p.apellido1 || ' ' || COALESCE(p.apellido2,'') AS alumno,
    m.nombre AS modulo,
    ma.curso_academico,
    ma.estado,
    ma.nota_final,
    (ma.detalle_nota).nota AS nota_detalle,
    (ma.detalle_nota).evaluacion,
    (ma.detalle_nota).fecha
FROM matricula ma
JOIN alumno a ON ma.alumno_id = a.id
JOIN persona p ON a.id = p.id
JOIN modulo m ON ma.modulo_id = m.id;

-- Inserciones de prueba

------------------------------------------
-- 1. CICLOS
------------------------------------------
INSERT INTO ciclo (codigo, nombre, turno, duracion_años)
VALUES
('DAM', 'Desarrollo de Aplicaciones Multiplataforma', 'mañana', 2),
('ASIR','Administración de Sistemas Informáticos', 'tarde', 2);

------------------------------------------
-- 2. MÓDULOS
------------------------------------------
INSERT INTO modulo (codigo, nombre, carrera_id, creditos, curso, max_alumnos)
VALUES
('PROG', 'Programación', (SELECT id FROM ciclo WHERE codigo='DAM'), 8, 1, 3),
('BBDD', 'Bases de Datos', (SELECT id FROM ciclo WHERE codigo='DAM'), 6, 1, 2),
('LMSG', 'Lenguajes de Marca', (SELECT id FROM ciclo WHERE codigo='DAM'), 4, 1, 3),
('SINF', 'Sistemas Informáticos', (SELECT id FROM ciclo WHERE codigo='ASIR'), 6, 1, 3);

------------------------------------------
-- 3. PROFESORES
------------------------------------------
INSERT INTO profesor (
    dni, nombre, apellido1, apellido2, fecha_nacimiento,
    num_empleado, fecha_contratacion, departamento
)
VALUES
('11111111A','Ana','García',NULL,'1980-05-10','P001','2010-09-01','Informática'),
('22222222B','Luis','Martínez',NULL,'1975-03-20','P002','2012-09-01','Informática');

------------------------------------------
-- 4. ALUMNOS
------------------------------------------
INSERT INTO alumno (
    dni, nombre, apellido1, apellido2, fecha_nacimiento,
    num_expediente, fecha_matriculacion, idiomas, direccion
)
VALUES
('33333333C','Carlos','López',NULL,'2003-02-15','A001','2023-09-01',ARRAY['Español','Inglés'],
 ROW('Calle Mayor',10,NULL,NULL,'28001','Madrid','Madrid','España')),
('44444444D','María','Pérez',NULL,'2002-06-20','A002','2023-09-01',ARRAY['Español'],
 ROW('Calle Sol',5,NULL,NULL,'03001','Alicante','Alicante','España')),
('55555555E','Lucía','Ruiz',NULL,'2003-09-12','A003','2023-09-01',ARRAY['Español','Francés'],
 ROW('Av. Mar',20,NULL,NULL,'11001','Cádiz','Cádiz','España'));

------------------------------------------
-- 5. MATRÍCULAS
------------------------------------------
-- Carlos
INSERT INTO matricula (alumno_id, modulo_id, curso_academico, estado, nota_final, detalle_nota)
VALUES
((SELECT id FROM alumno WHERE num_expediente='A001'),
 (SELECT id FROM modulo WHERE codigo='PROG'), '2023-2024','aprobada',7.50, ROW('Ordinaria',7.50,'2024-06-20','Buen trabajo')),
((SELECT id FROM alumno WHERE num_expediente='A001'),
 (SELECT id FROM modulo WHERE codigo='BBDD'), '2023-2024','aprobada',8.00, ROW('Ordinaria',8.00,'2024-06-22','Excelente')),
((SELECT id FROM alumno WHERE num_expediente='A001'),
 (SELECT id FROM modulo WHERE codigo='LMSG'), '2023-2024','suspendida',4.00, ROW('Ordinaria',4.00,'2024-06-25','Debe mejorar'));

-- María
INSERT INTO matricula (alumno_id, modulo_id, curso_academico, estado, nota_final, detalle_nota)
VALUES
((SELECT id FROM alumno WHERE num_expediente='A002'),
 (SELECT id FROM modulo WHERE codigo='PROG'), '2023-2024','aprobada',6.50, ROW('Ordinaria',6.50,'2024-06-20','Correcto')),
((SELECT id FROM alumno WHERE num_expediente='A002'),
 (SELECT id FROM modulo WHERE codigo='BBDD'), '2023-2024','suspendida',3.50, ROW('Ordinaria',3.50,'2024-06-22','Insuficiente')),
((SELECT id FROM alumno WHERE num_expediente='A002'),
 (SELECT id FROM modulo WHERE codigo='LMSG'), '2023-2024','aprobada',7.00, ROW('Ordinaria',7.00,'2024-06-25','Bien'));

-- Lucía
INSERT INTO matricula (alumno_id, modulo_id, curso_academico, estado, nota_final, detalle_nota)
VALUES
((SELECT id FROM alumno WHERE num_expediente='A003'),
 (SELECT id FROM modulo WHERE codigo='PROG'), '2023-2024','aprobada',9.00, ROW('Ordinaria',9.00,'2024-06-20','Sobresaliente')),
((SELECT id FROM alumno WHERE num_expediente='A003'),
 (SELECT id FROM modulo WHERE codigo='LMSG'), '2023-2024','aprobada',8.50, ROW('Ordinaria',8.50,'2024-06-25','Muy bien')),
((SELECT id FROM alumno WHERE num_expediente='A003'),
 (SELECT id FROM modulo WHERE codigo='SINF'), '2023-2024','aprobada',7.00, ROW('Ordinaria',7.00,'2024-06-28','Correcto'));

------------------------------------------
-- 6. PRUEBA TRIGGER DE AFORO
------------------------------------------
DO $$
BEGIN
    BEGIN
        INSERT INTO matricula (
            alumno_id, modulo_id, curso_academico, estado, detalle_nota
        )
        VALUES (
            (SELECT id FROM alumno WHERE num_expediente='A003'),
            (SELECT id FROM modulo WHERE codigo='BBDD'),
            '2023-2024','activa', ROW('Ordinaria',NULL,NULL,NULL)
        );
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'Trigger de aforo bloqueó la matrícula de Lucía en BBDD';
    END;
END;
$$;

------------------------------------------
-- 7. COMPROBAR TRIGGERS DE MEDIA Y CRÉDITOS
------------------------------------------
SELECT id, nombre, apellidos, media_global, creditos_superados, creditos_matriculados
FROM vw_alumnos_resumen;

------------------------------------------
-- 8. VISTAS
------------------------------------------
SELECT * FROM vw_matriculas_detalle;
SELECT * FROM vw_docencia;
