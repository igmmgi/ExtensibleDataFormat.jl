# xml.jl

"""
    parse_xml(xml::String) -> Dict{String, Any}

Parses a raw XML string into a nested Dictionary natively, without external dependencies.
Identical sibling tags (e.g., `<channel>`) are grouped into Arrays.
"""
function parse_xml(xml::String)
    xml = replace(xml, r"<\?xml.*?\?>" => "")
    xml = replace(xml, r"<!--.*?-->"s => "")
    xml = strip(xml)
    return _parse_element(xml)
end

function _parse_element(xml::AbstractString)
    res = Dict{String, Any}()
    pos = 1
    len = length(xml)
    has_elements = false
    
    while pos <= len
        start_tag_open = findnext("<", xml, pos)
        if start_tag_open === nothing
            break
        end
        
        start_tag_close = findnext(">", xml, start_tag_open[1])
        if start_tag_close === nothing
            break
        end
        
        tag_content = xml[start_tag_open[1]+1 : start_tag_close[1]-1]
        
        if endswith(tag_content, "/")
            tag_name = String(strip(tag_content[1:end-1]))
            _add_to_dict!(res, tag_name, "")
            pos = start_tag_close[1] + 1
            has_elements = true
            continue
        end
        
        tag_name = String(split(tag_content, " ")[1])
        
        closing_tag = "</$tag_name>"
        
        # Simplified parser assumes XDF streams do not use deeply nested self-identical tags like <desc><desc>
        end_tag_open = findnext(closing_tag, xml, start_tag_close[1])
        
        if end_tag_open === nothing
            pos = start_tag_close[1] + 1
            continue
        end
        
        inner_content = strip(xml[start_tag_close[1]+1 : end_tag_open[1]-1])
        
        # Check if inner content has tags
        if occursin(r"<[a-zA-Z0-9_:-]+[^>]*>", inner_content)
            parsed_inner = _parse_element(inner_content)
            _add_to_dict!(res, tag_name, parsed_inner)
        else
            _add_to_dict!(res, tag_name, String(inner_content))
        end
        
        pos = end_tag_open[end] + 1
        has_elements = true
    end
    
    if !has_elements
        return String(xml)
    end
    
    return res
end

function _add_to_dict!(d::Dict, k::String, v::Any)
    if haskey(d, k)
        if !(typeof(d[k]) <: Vector)
            d[k] = Any[d[k]]
        end
        push!(d[k], v)
    else
        d[k] = v
    end
end
