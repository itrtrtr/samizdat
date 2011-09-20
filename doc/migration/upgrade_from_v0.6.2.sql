-- Samizdat Database Migration from v0.6.2 - PostgreSQL
--
--   Copyright (c) 2002-2009  Dmitry Borodaenko <angdraug@debian.org>
--
--   This program is free software.
--   You can distribute/modify this program under the terms of
--   the GNU General Public License version 3 or later.
--

BEGIN;

-- update tables

ALTER TABLE Member
        ALTER COLUMN full_name DROP NOT NULL;

ALTER TABLE Message
        ADD COLUMN locked BOOLEAN;

ALTER TABLE Resource
        ADD COLUMN part_of INTEGER REFERENCES Resource,
        ADD COLUMN part_of_subproperty INTEGER REFERENCES Resource,
        ADD COLUMN part_sequence_number INTEGER;

CREATE INDEX Resource_part_of_idx ON Resource (part_of);

REVOKE INSERT, UPDATE ON Role FROM samizdat;

-- create new tables

CREATE TABLE Event (
        id INTEGER PRIMARY KEY REFERENCES Resource,
        description INTEGER REFERENCES Message,
        dtstart TIMESTAMP WITH TIME ZONE NOT NULL,
        dtend TIMESTAMP WITH TIME ZONE);

CREATE INDEX Event_dtstart_idx ON Event (dtstart);

CREATE TYPE RecurrenceFreq AS ENUM ('secondly', 'minutely', 'hourly', 'daily',
        'weekly', 'monthly', 'yearly');

CREATE TABLE Recurrence (
        id INTEGER PRIMARY KEY REFERENCES Resource,
        event INTEGER REFERENCES Event,
        freq RecurrenceFreq DEFAULT 'daily' NOT NULL,
        interval INTEGER DEFAULT 1 NOT NULL,
        until TIMESTAMP WITH TIME ZONE,
        byday TEXT,
        byhour TEXT);

CREATE INDEX Recurrence_event_until_idx ON Recurrence (event, until);

CREATE TABLE Part (
        id INTEGER REFERENCES Resource,
        part_of INTEGER REFERENCES Resource,
        part_of_subproperty INTEGER REFERENCES Resource,
        distance INTEGER DEFAULT 0 NOT NULL);

CREATE INDEX Part_id_idx ON Part (id);
CREATE INDEX Part_part_of_idx ON Part (part_of);

CREATE TABLE Tag (
        id INTEGER PRIMARY KEY REFERENCES Resource,
        nrelated INTEGER,
        nrelated_with_subtags INTEGER);

CREATE TYPE PendingUploadStatus AS ENUM ('pending', 'confirmed', 'expired');

CREATE TABLE PendingUpload (
        id SERIAL PRIMARY KEY,
        created_date TIMESTAMP WITH TIME ZONE
                DEFAULT CURRENT_TIMESTAMP NOT NULL,
        login TEXT NOT NULL,
        status PendingUploadStatus DEFAULT 'pending' NOT NULL);

CREATE INDEX PendingUpload_status_idx ON PendingUpload (login, status);

CREATE TABLE PendingUploadFile (
        upload INTEGER NOT NULL REFERENCES PendingUpload,
        part INTEGER,
        UNIQUE (upload, part),
        format TEXT,
        original_filename TEXT);

CREATE INDEX PendingUploadFile_upload_idx ON PendingUploadFile (upload);

-- grant access to new tables (change samizdat to your user if different)

GRANT INSERT, UPDATE, SELECT ON Event, Recurrence, Tag,
        PendingUpload, PendingUploadFile TO samizdat;
GRANT INSERT, UPDATE, DELETE, SELECT ON Part TO samizdat;
GRANT USAGE, UPDATE, SELECT ON PendingUpload_id_seq TO samizdat;

-- update triggers

CREATE TRIGGER insert_event BEFORE INSERT ON Event
    FOR EACH ROW EXECUTE PROCEDURE insert_resource('Event');

CREATE TRIGGER insert_recurrence BEFORE INSERT ON Recurrence
    FOR EACH ROW EXECUTE PROCEDURE insert_resource('Recurrence');

CREATE TRIGGER delete_event AFTER DELETE ON Event
    FOR EACH ROW EXECUTE PROCEDURE delete_resource();

CREATE TRIGGER delete_recurrence AFTER DELETE ON Recurrence
    FOR EACH ROW EXECUTE PROCEDURE delete_resource();

DROP FUNCTION update_rating() CASCADE;

CREATE FUNCTION select_subproperty(value Resource.id%TYPE, subproperty Resource.id%TYPE) RETURNS Resource.id%TYPE AS $$
    BEGIN
        IF subproperty IS NULL THEN
            RETURN NULL;
        ELSE
            RETURN value;
        END IF;
    END;
$$ LANGUAGE 'plpgsql';

CREATE FUNCTION calculate_statement_rating(statement_id Statement.id%TYPE) RETURNS Statement.rating%TYPE AS $$
    BEGIN
        RETURN (SELECT AVG(rating) FROM Vote WHERE proposition = statement_id);
    END;
$$ LANGUAGE 'plpgsql';

CREATE FUNCTION update_nrelated(tag_id Resource.id%TYPE) RETURNS VOID AS $$
    DECLARE
        dc_relation Resource.label%TYPE := 'http://purl.org/dc/elements/1.1/relation';
        s_subtag_of Resource.label%TYPE := 'http://www.nongnu.org/samizdat/rdf/schema#subTagOf';
        s_subtag_of_id Resource.id%TYPE;
        n Tag.nrelated%TYPE;
        supertag RECORD;
    BEGIN
        -- update nrelated
        SELECT COUNT(*) INTO n
            FROM Statement s
            INNER JOIN Resource p ON s.predicate = p.id
            WHERE p.label = dc_relation AND s.object = tag_id AND s.rating > 0;

        UPDATE Tag SET nrelated = n WHERE id = tag_id;
        IF NOT FOUND THEN
            INSERT INTO Tag (id, nrelated) VALUES (tag_id, n);
        END IF;

        -- update nrelated_with_subtags for this tag and its supertags
        SELECT id INTO s_subtag_of_id FROM Resource
            WHERE label = s_subtag_of;

        FOR supertag IN (
            SELECT tag_id AS id, 0 AS distance
                UNION
                SELECT part_of AS id, distance FROM Part
                    WHERE id = tag_id
                    AND part_of_subproperty = s_subtag_of_id
                ORDER BY distance ASC)
        LOOP
            UPDATE Tag
                SET nrelated_with_subtags = nrelated + COALESCE((
                    SELECT SUM(subt.nrelated)
                        FROM Part p
                        INNER JOIN Tag subt ON subt.id = p.id
                        WHERE p.part_of = supertag.id
                        AND p.part_of_subproperty = s_subtag_of_id), 0)
                WHERE id = supertag.id;
        END LOOP;
    END;
$$ LANGUAGE 'plpgsql';

CREATE FUNCTION update_nrelated_if_subtag(tag_id Resource.id%TYPE, property Resource.id%TYPE) RETURNS VOID AS $$
    DECLARE
        s_subtag_of Resource.label%TYPE := 'http://www.nongnu.org/samizdat/rdf/schema#subTagOf';
        s_subtag_of_id Resource.id%TYPE;
    BEGIN
        SELECT id INTO s_subtag_of_id FROM Resource
            WHERE label = s_subtag_of;

        IF property = s_subtag_of_id THEN
            PERFORM update_nrelated(tag_id);
        END IF;
    END;
$$ LANGUAGE 'plpgsql';

CREATE FUNCTION update_rating() RETURNS TRIGGER AS $$
    DECLARE
        dc_relation Resource.label%TYPE := 'http://purl.org/dc/elements/1.1/relation';
        old_rating Statement.rating%TYPE;
        new_rating Statement.rating%TYPE;
        tag_id Resource.id%TYPE;
        predicate_uriref Resource.label%TYPE;
    BEGIN
        -- save some values for later reference
        SELECT s.rating, s.object, p.label
            INTO old_rating, tag_id, predicate_uriref
            FROM Statement s
            INNER JOIN Resource p ON s.predicate = p.id
            WHERE s.id = NEW.proposition;

        -- set new rating of the proposition
        new_rating := calculate_statement_rating(NEW.proposition);
        UPDATE Statement SET rating = new_rating WHERE id = NEW.proposition;

        -- check if new rating reverts truth value of the proposition
        IF predicate_uriref = dc_relation
            AND (((old_rating IS NULL OR old_rating <= 0) AND new_rating > 0) OR
                (old_rating > 0 AND new_rating <= 0))
        THEN
            PERFORM update_nrelated(tag_id);
        END IF;

        RETURN NEW;
    END;
$$ LANGUAGE 'plpgsql';

CREATE TRIGGER update_rating AFTER INSERT OR UPDATE OR DELETE ON Vote
    FOR EACH ROW EXECUTE PROCEDURE update_rating();

CREATE FUNCTION before_update_part() RETURNS TRIGGER AS $$
    BEGIN
        IF TG_OP = 'INSERT' THEN
            IF NEW.part_of IS NULL THEN
                RETURN NEW;
            END IF;
        ELSIF TG_OP = 'UPDATE' THEN
            IF (NEW.part_of = OLD.part_of) OR
                (NEW.part_of IS NULL AND OLD.part_of IS NULL)
            THEN
                -- part_of is unchanged, do nothing
                RETURN NEW;
            END IF;
        END IF;

        -- check for loops
        IF NEW.part_of = NEW.id OR NEW.part_of IN (
            SELECT id FROM Part WHERE part_of = NEW.id)
        THEN
            -- unset part_of, but don't fail whole query
            NEW.part_of = NULL;
            NEW.part_of_subproperty = NULL;

            IF TG_OP != 'INSERT' THEN
                -- check it was a subtag link
                PERFORM update_nrelated_if_subtag(OLD.id, OLD.part_of_subproperty);
            END IF;

            RETURN NEW;
        END IF;

        RETURN NEW;
    END;
$$ LANGUAGE 'plpgsql';

CREATE TRIGGER before_update_part BEFORE INSERT OR UPDATE ON Resource
    FOR EACH ROW EXECUTE PROCEDURE before_update_part();

CREATE FUNCTION after_update_part() RETURNS TRIGGER AS $$
    BEGIN
        IF TG_OP = 'INSERT' THEN
            IF NEW.part_of IS NULL THEN
                RETURN NEW;
            END IF;
        ELSIF TG_OP = 'UPDATE' THEN
            IF (NEW.part_of = OLD.part_of) OR
                (NEW.part_of IS NULL AND OLD.part_of IS NULL)
            THEN
                -- part_of is unchanged, do nothing
                RETURN NEW;
            END IF;
        END IF;

        IF TG_OP != 'INSERT' THEN
            IF OLD.part_of IS NOT NULL THEN
                -- clean up links generated for old part_of
                DELETE FROM Part
                    WHERE id IN (
                        -- for old resource...
                        SELECT OLD.id
                        UNION
                        --...and all its parts, ...
                        SELECT id FROM Part WHERE part_of = OLD.id)
                    AND part_of IN (
                        -- ...remove links to all parents of old resource
                        SELECT part_of FROM Part WHERE id = OLD.id)
                    AND part_of_subproperty = OLD.part_of_subproperty;
            END IF;
        END IF;

        IF TG_OP != 'DELETE' THEN
            IF NEW.part_of IS NOT NULL THEN
                -- generate links to the parent and grand-parents of new resource
                INSERT INTO Part (id, part_of, part_of_subproperty, distance)
                    SELECT NEW.id, NEW.part_of, NEW.part_of_subproperty, 1
                    UNION
                    SELECT NEW.id, part_of, NEW.part_of_subproperty, distance + 1
                        FROM Part
                        WHERE id = NEW.part_of
                        AND part_of_subproperty = NEW.part_of_subproperty;

                -- generate links from all parts of new resource to all its parents
                INSERT INTO Part (id, part_of, part_of_subproperty, distance)
                    SELECT child.id, parent.part_of, NEW.part_of_subproperty,
                           child.distance + parent.distance
                        FROM Part child
                        INNER JOIN Part parent
                            ON parent.id = NEW.id
                            AND parent.part_of_subproperty = NEW.part_of_subproperty
                        WHERE child.part_of = NEW.id
                        AND child.part_of_subproperty = NEW.part_of_subproperty;
            END IF;
        END IF;

        -- check if subtag link was affected
        IF TG_OP != 'DELETE' THEN
            PERFORM update_nrelated_if_subtag(NEW.id, NEW.part_of_subproperty);
        END IF;
        IF TG_OP != 'INSERT' THEN
            PERFORM update_nrelated_if_subtag(OLD.id, OLD.part_of_subproperty);
        END IF;

        RETURN NEW;
    END;
$$ LANGUAGE 'plpgsql';

CREATE TRIGGER after_update_part AFTER INSERT OR UPDATE OR DELETE ON Resource
    FOR EACH ROW EXECUTE PROCEDURE after_update_part();

-- update data

UPDATE Resource
        SET label = 'http://www.nongnu.org/samizdat/rdf/tag#Translation'
        WHERE literal = 'false' AND uriref = 'true'
        AND label = 'http://www.nongnu.org/samizdat/rdf/focus#Translation';

CREATE FUNCTION upgrade() RETURNS VOID AS $$
    DECLARE
        version_of Resource.label%TYPE := 'http://purl.org/dc/terms/isVersionOf';
        version_of_id Resource.id%TYPE;
        dc_relation Resource.label%TYPE := 'http://purl.org/dc/elements/1.1/relation';
        translation Resource.label%TYPE := 'http://www.nongnu.org/samizdat/rdf/tag#Translation';
        translation_of Resource.label%TYPE := 'http://www.nongnu.org/samizdat/rdf/schema#isTranslationOf';
        translation_of_id Resource.id%TYPE;
        in_reply_to Resource.label%TYPE := 'http://www.nongnu.org/samizdat/rdf/schema#inReplyTo';
        in_reply_to_id Resource.id%TYPE;
        t Resource.id%TYPE;
    BEGIN
        -- transform isVersionOf into subproperty of isPartOf
        SELECT id INTO version_of_id FROM Resource
            WHERE label = 'false' AND uriref = 'true' AND label = version_of;
        IF NOT FOUND THEN
            INSERT INTO Resource (uriref, label) VALUES ('true', version_of)
                RETURNING id INTO version_of_id;
        END IF;

        UPDATE Resource r
            SET part_of = m.version_of, part_of_subproperty = version_of_id
            FROM Message m
            WHERE r.part_of IS NULL
            AND m.id = r.id
            AND m.version_of IS NOT NULL;

        -- transform (reply dc::relation tag::Translation) into subproperty of isPartOf
        SELECT id INTO translation_of_id FROM Resource
            WHERE label = 'false' AND uriref = 'true' AND label = translation_of;
        IF NOT FOUND THEN
            INSERT INTO Resource (uriref, label) VALUES ('true', translation_of)
                RETURNING id INTO translation_of_id;
        END IF;

        UPDATE Resource r
            SET part_of = m.parent, part_of_subproperty = translation_of_id
            FROM Message m, Statement s, Resource p, Resource tr
            WHERE r.part_of IS NULL
            AND m.id = r.id
            AND m.parent IS NOT NULL
            AND s.subject = m.id
            AND s.predicate = p.id AND p.label = dc_relation
            AND s.object = tr.id AND tr.label = translation;

        UPDATE Vote v
            SET rating = -2
            FROM Resource tr, Statement s
            WHERE v.proposition = s.id AND s.object = tr.id AND tr.label = translation;

        -- transform inReplyTo into subproperty of isPartOf
        SELECT id INTO in_reply_to_id FROM Resource
            WHERE label = 'false' AND uriref = 'true' AND label = in_reply_to;
        IF NOT FOUND THEN
            INSERT INTO Resource (uriref, label) VALUES ('true', in_reply_to)
                RETURNING id INTO in_reply_to_id;
        END IF;

        UPDATE Resource r
            SET part_of = m.parent, part_of_subproperty = in_reply_to_id
            FROM Message m
            WHERE r.part_of IS NULL
            AND m.id = r.id
            AND m.parent IS NOT NULL;

        -- calculate nrelated for all tags
        FOR t IN (
            SELECT DISTINCT s.object
                FROM Statement s, Resource p
                WHERE s.rating > 0
                AND s.predicate = p.id AND p.label = dc_relation)
        LOOP
            PERFORM update_nrelated(t);
        END LOOP;
    END;
$$ LANGUAGE 'plpgsql';

SELECT upgrade();

DROP FUNCTION upgrade();

ALTER TABLE Message DROP COLUMN parent;
ALTER TABLE Message DROP COLUMN description;
ALTER TABLE Message DROP COLUMN version_of;

COMMIT;