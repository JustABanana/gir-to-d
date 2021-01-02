/*
 * This file is part of gir-to-d.
 *
 * gir-to-d is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License
 * as published by the Free Software Foundation, either version 3
 * of the License, or (at your option) any later version.
 *
 * gir-to-d is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with gir-to-d.  If not, see <http://www.gnu.org/licenses/>.
 */

module gtd.GirField;

import std.algorithm: among, endsWith;
import std.conv;
import std.range;
import std.string: splitLines, strip;

import gtd.Log;
import gtd.GirFunction;
import gtd.GirStruct;
import gtd.GirType;
import gtd.GirWrapper;
import gtd.XMLReader;

final class GirField
{
	string name;
	string doc;
	GirType type;
	int bits = -1;
	bool writable = false;
	bool isLength = false;   ///This field holds the length of an other field.
	bool noProperty = false; ///Don't generate a property for this field.

	GirFunction callback;
	GirUnion gtkUnion;
	GirStruct gtkStruct;

	GirWrapper wrapper;
	GirStruct strct;

	this(GirWrapper wrapper, GirStruct strct)
	{
		this.wrapper = wrapper;
		this.strct = strct;
	}

	void parse(T)(XMLReader!T reader)
	{
		name = reader.front.attributes["name"];

		if ( "bits" in reader.front.attributes )
			bits = to!int(reader.front.attributes["bits"]);
		if ( auto write = "writable" in reader.front.attributes )
			writable = *write == "1";

		//TODO: readable private?

		reader.popFront();

		while( !reader.empty && !reader.endTag("field") )
		{
			if ( reader.front.type == XMLNodeType.EndTag )
			{
				reader.popFront();
				continue;
			}

			switch(reader.front.value)
			{
				case "doc":
					reader.popFront();
					doc ~= reader.front.value;
					reader.popFront();
					break;
				case "doc-deprecated":
					reader.popFront();
					doc ~= "\n\nDeprecated: "~ reader.front.value;
					reader.popFront();
					break;
				case "array":
				case "type":
					type = new GirType(wrapper);
					type.parse(reader);
					break;
				case "callback":
					callback = new GirFunction(wrapper, strct);
					callback.parse(reader);
					break;
				case "source-position":
					reader.skipTag();
					break;
				default:
					warning("Unexpected tag: ", reader.front.value, " in GirField: ", name, reader);
			}
			reader.popFront();
		}
	}

	/**
	 * A special case for fields, we need to know about all of then
	 * to properly construct the bitfields.
	 */
	static string[] getFieldDeclarations(GirField[] fields, GirWrapper wrapper)
	{
		string[] buff;
		int bitcount;

		void endBitfield()
		{
			//AFAIK: C bitfields are padded to a multiple of sizeof uint.
			int padding = 32 - (bitcount % 32);

			if ( padding > 0 && padding < 32)
			{
				buff[buff.length-1] ~= ",";
				buff ~= "uint, \"\", "~ to!string(padding);
				buff ~= "));";
			}
			else
			{
				buff ~= "));";
			}

			bitcount = 0;
		}

		foreach ( field; fields )
		{
			if ( field.callback )
			{
				if ( bitcount > 0 )
					endBitfield();
				buff ~= field.callback.getFunctionPointerDeclaration();
				continue;
			}

			if ( field.gtkUnion )
			{
				if ( bitcount > 0 )
					endBitfield();
				buff ~= field.gtkUnion.getUnionDeclaration();
				continue;
			}

			if ( field.gtkStruct )
			{
				if ( bitcount > 0 )
					endBitfield();
				buff ~= field.gtkStruct.getStructDeclaration();
				buff ~= stringToGtkD(field.gtkStruct.cType ~" "~ field.gtkStruct.name ~";", wrapper.aliasses);
				continue;
			}

			if ( field.bits > 0 )
			{
				if ( bitcount == 0 )
				{
					buff ~= "import std.bitmanip: bitfields;";
					buff ~= "mixin(bitfields!(";
				}
				else
				{
					buff[buff.length-1] ~= ",";
				}

				bitcount += field.bits;
				buff ~= stringToGtkD(field.type.cType ~", \""~ field.name ~"\", "~ to!string(field.bits), wrapper.aliasses);
				continue;
			}
			else if ( bitcount > 0)
			{
				endBitfield();
			}

			if ( field.doc !is null && wrapper.includeComments && field.bits < 0 )
			{
				buff ~= "/**";
				foreach ( line; field.doc.splitLines() )
					buff ~= " * "~ line.strip();
				buff ~= " */";
			}

			string dType;

			if ( field.type.size == -1 )
			{
				if ( field.type.cType.empty )
					dType = stringToGtkD(field.type.name, wrapper.aliasses, false);
				else
					dType = stringToGtkD(field.type.cType, wrapper.aliasses, false);
			}
			else if ( field.type.elementType.cType.empty )
			{
				//Special case for GObject.Value.
				dType = stringToGtkD(field.type.elementType.name, wrapper.aliasses, false);
				dType ~= "["~ to!string(field.type.size) ~"]";
			}
			else
			{
				dType = stringToGtkD(field.type.elementType.cType, wrapper.aliasses, false);
				dType ~= "["~ to!string(field.type.size) ~"]";
			}

			buff ~= dType ~" "~ tokenToGtkD(field.name, wrapper.aliasses) ~";";
		}

		if ( bitcount > 0)
		{
			endBitfield();
		}

		return buff;
	}

	string[] getProperty()
	{
		string[] buff;

		if ( !writable || isLength || noProperty )
			return null;

		writeDocs(buff);
		writeGetter(buff);

		buff ~= "";
		if ( wrapper.includeComments )
			buff ~= "/** Ditto */";

		writeSetter(buff);

		return buff;
	}

	private void writeGetter(ref string[] buff)
	{
		GirStruct dType;
		string dTypeName;

		if ( type.isArray() )
			dType = strct.pack.getStruct(type.elementType.name);
		else if ( auto dStrct = strct.pack.getStruct(strct.structWrap.get(type.name, "")) )
			dType = dStrct;
		else
			dType = strct.pack.getStruct(type.name);

		if ( dType )
		{
			if ( dType.name in strct.structWrap )
				dTypeName = strct.structWrap[dType.name];
			else if ( dType.type == GirStructType.Interface )
				dTypeName = dType.name ~"IF";
			else
				dTypeName = dType.name;
		}

		if ( type.isString() )
		{
			if ( type.isArray() && type.elementType.isString() )
			{
				buff ~= "public @property string["~ ((type.size > 0)?type.size.to!string:"") ~"] "~ tokenToGtkD(name, wrapper.aliasses, strct.aliases) ~"()";
				buff ~= "{";

				if ( type.length > -1 )
					buff ~= "return Str.toStringArray("~ strct.getHandleVar() ~"."~ tokenToGtkD(name, wrapper.aliasses) ~", "~ getLengthID(strct) ~");";
				else if ( type.size > 0 )
				{
					buff ~= "string["~ type.size.to!string ~"] arr;";
					buff ~= "foreach( i, str; "~ strct.getHandleVar() ~"."~ tokenToGtkD(name, wrapper.aliasses) ~" )";
					buff ~= "{";
					buff ~= "arr[i] = Str.toString(str);";
					buff ~= "}";
					buff ~= "return arr;";
				}
				else
					buff ~= "return Str.toStringArray("~ strct.getHandleVar() ~"."~ tokenToGtkD(name, wrapper.aliasses) ~");";

				buff ~= "}";
			}
			else
			{
				if ( type.size > 0 )
				{
					buff ~= "public @property char["~ type.size.to!string ~"] "~ tokenToGtkD(name, wrapper.aliasses, strct.aliases) ~"()";
					buff ~= "{";
					buff ~= "return "~ strct.getHandleVar() ~"."~ tokenToGtkD(name, wrapper.aliasses) ~";";
					buff ~= "}";
				}
				else
				{
					buff ~= "public @property string "~ tokenToGtkD(name, wrapper.aliasses, strct.aliases) ~"()";
					buff ~= "{";
					buff ~= "return Str.toString("~ strct.getHandleVar() ~"."~ tokenToGtkD(name, wrapper.aliasses) ~");";
					buff ~= "}";
				}
			}
		}
		else if ( dType && dType.isDClass() && type.cType.endsWith("*") )
		{
			if ( type.isArray() )
			{
				buff ~= "public @property "~ dTypeName ~"["~ ((type.size > 0)?type.size.to!string:"") ~"] "~ tokenToGtkD(name, wrapper.aliasses, strct.aliases) ~"()";
				buff ~= "{";

				if ( type.length > -1 )
					buff ~= dTypeName ~"[] arr = new "~ dTypeName ~"["~ getLengthID(strct) ~"];";
				else if ( type.size > 0 )
					buff ~= dTypeName ~"["~ type.size.to!string ~"] arr;";
				else
					buff ~= dTypeName ~"[] arr = new "~ dTypeName ~"[getArrayLength("~ strct.getHandleVar() ~"."~ tokenToGtkD(name, wrapper.aliasses) ~")];";
				
				buff ~= "for ( int i = 0; i < arr.length; i++ )";
				buff ~= "{";
				
				if ( dType.pack.name.among("cairo", "glib", "gthread") )
					buff ~= "arr[i] = new "~ dTypeName ~"("~ strct.getHandleVar() ~"."~ tokenToGtkD(name, wrapper.aliasses) ~"[i], false);";
				else if( dType.type == GirStructType.Interface )
					buff ~= "arr[i] = ObjectG.getDObject!("~ dTypeName ~"IF)("~ strct.getHandleVar() ~"."~ tokenToGtkD(name, wrapper.aliasses) ~"[i], false);";
				else
					buff ~= "arr[i] = ObjectG.getDObject!("~ dTypeName ~")("~ strct.getHandleVar() ~"."~ tokenToGtkD(name, wrapper.aliasses) ~"[i], false);";

				buff ~= "}";
				buff ~= "";
				buff ~= "return arr;";
				buff ~= "}";
			}
			else
			{
				buff ~= "public @property "~ dTypeName ~" "~ tokenToGtkD(name, wrapper.aliasses, strct.aliases) ~"()";
				buff ~= "{";
				
				if ( dType.pack.name.among("cairo", "glib", "gthread") )
					buff ~= "return new "~ dTypeName ~"("~ strct.getHandleVar() ~"."~ tokenToGtkD(name, wrapper.aliasses) ~", false);";
				else if( dType.type == GirStructType.Interface )
					buff ~= "return ObjectG.getDObject!("~ dTypeName ~"IF)("~ strct.getHandleVar() ~"."~ tokenToGtkD(name, wrapper.aliasses) ~", false);";
				else
					buff ~= "return ObjectG.getDObject!("~ dTypeName ~")("~ strct.getHandleVar() ~"."~ tokenToGtkD(name, wrapper.aliasses) ~", false);";

				buff ~= "}";
			}
		}
		else if ( type.name.among("bool", "gboolean") || ( type.isArray && type.elementType.name.among("bool", "gboolean") ) )
		{
			if ( type.isArray() )
			{
				buff ~= "public @property bool["~ ((type.size > 0)?type.size.to!string:"") ~"] "~ tokenToGtkD(name, wrapper.aliasses, strct.aliases) ~"()";
				buff ~= "{";

				if ( type.length > -1 )
					buff ~= "return "~ strct.getHandleVar ~"."~ tokenToGtkD(name, wrapper.aliasses) ~"[0.."~ getLengthID(strct) ~"];";
				else if ( type.size > 0 )
					buff ~= "return "~ strct.getHandleVar ~"."~ tokenToGtkD(name, wrapper.aliasses) ~";";
				else
					error("Is boolean[] field: ", strct.name, ".", name, " really zero terminated?");

				buff ~= "}";
			}
			else
			{
				buff ~= "public @property bool "~ tokenToGtkD(name, wrapper.aliasses, strct.aliases) ~"()";
				buff ~= "{";
				buff ~= "return "~ strct.getHandleVar() ~"."~ tokenToGtkD(name, wrapper.aliasses) ~" != 0;";
				buff ~= "}";
			}
		}
		else
		{
			if ( type.isArray() )
			{
				if ( type.size > 0 && dType && dType.isDClass() )
				{
					buff ~= "public @property "~ dTypeName ~"["~ type.size.to!string() ~"] "~ tokenToGtkD(name, wrapper.aliasses, strct.aliases) ~"()";
					buff ~= "{";
					buff ~= dTypeName ~"["~ type.size.to!string() ~"] arr;";

					buff ~= "for ( int i = 0; i < arr.length; i++ )";
					buff ~= "{";
					
					if ( dType.pack.name.among("cairo", "glib", "gthread") )
						buff ~= "arr[i] = new "~ dTypeName ~"(&("~ strct.getHandleVar() ~"."~ tokenToGtkD(name, wrapper.aliasses) ~"[i]), false);";
					else if( dType.type == GirStructType.Interface )
						buff ~= "arr[i] = ObjectG.getDObject!("~ dTypeName ~"IF)(&("~ strct.getHandleVar() ~"."~ tokenToGtkD(name, wrapper.aliasses) ~"[i]), false);";
					else
						buff ~= "arr[i] = ObjectG.getDObject!("~ dTypeName ~")(&("~ strct.getHandleVar() ~"."~ tokenToGtkD(name, wrapper.aliasses) ~"[i]), false);";

					buff ~= "}";
					buff ~= "";
					buff ~= "return arr;";
					buff ~= "}";
				}
				else if ( type.size > 0 )
				{
					buff ~= "public @property "~ stringToGtkD(type.cType, wrapper.aliasses, strct.aliases) ~"["~ ((type.size > 0)?type.size.to!string:"") ~"] "~ tokenToGtkD(name, wrapper.aliasses, strct.aliases) ~"()";
					buff ~= "{";
					buff ~= "return "~ strct.getHandleVar() ~"."~ tokenToGtkD(name, wrapper.aliasses) ~";";
					buff ~= "}";
				}
				else
				{
					buff ~= "public @property "~ stringToGtkD(type.cType[0..$-1], wrapper.aliasses, strct.aliases) ~"["~ ((type.size > 0)?type.size.to!string:"") ~"] "~ tokenToGtkD(name, wrapper.aliasses, strct.aliases) ~"()";
					buff ~= "{";

					if ( type.length > -1 )
						buff ~= "return "~ strct.getHandleVar() ~"."~ tokenToGtkD(name, wrapper.aliasses) ~"[0.."~ getLengthID(strct) ~"];";
					else
						buff ~= "return "~ strct.getHandleVar() ~"."~ tokenToGtkD(name, wrapper.aliasses) ~"[0..getArrayLength("~ strct.getHandleVar() ~"."~ tokenToGtkD(name, wrapper.aliasses) ~")];";
					
					buff ~= "}";
				}
			}
			else
			{
				buff ~= "public @property "~ stringToGtkD(type.cType, wrapper.aliasses, strct.aliases) ~" "~ tokenToGtkD(name, wrapper.aliasses, strct.aliases) ~"()";
				buff ~= "{";
				buff ~= "return "~ strct.getHandleVar() ~"."~ tokenToGtkD(name, wrapper.aliasses) ~";";
				buff ~= "}";
			}
		}
	}

	private void writeSetter(ref string[] buff)
	{
		GirStruct dType;
		string    dTypeName;

		if ( type.isArray() )
			dType = strct.pack.getStruct(type.elementType.name);
		else if ( auto dStrct = strct.pack.getStruct(strct.structWrap.get(type.name, "")) )
			dType = dStrct;
		else
			dType = strct.pack.getStruct(type.name);

		if ( dType )
		{
			if ( dType.name in strct.structWrap )
				dTypeName = strct.structWrap[dType.name];
			else if ( dType.type == GirStructType.Interface )
				dTypeName = dType.name ~"IF";
			else
				dTypeName = dType.name;
		}

		if ( type.isString() )
		{
			if ( type.isArray() && type.elementType.isString() )
			{
				buff ~= "public @property void "~ tokenToGtkD(name, wrapper.aliasses, strct.aliases) ~"(string["~ ((type.size > 0)?type.size.to!string:"") ~"] value)";
				buff ~= "{";

				if ( type.size > 0 )
				{
					buff ~= stringToGtkD(type.elementType.cType, wrapper.aliasses) ~"["~ type.size.to!string ~"] arr;";
					buff ~= "foreach( i, str; value )";
					buff ~= "{";
					buff ~= "arr[i] = Str.toStringz(str);";
					buff ~= "}";
					buff ~= strct.getHandleVar() ~"."~ tokenToGtkD(name, wrapper.aliasses) ~" = arr;";
				}
				else
				{
					buff ~= strct.getHandleVar() ~"."~ tokenToGtkD(name, wrapper.aliasses) ~" = Str.toStringzArray(value);";
					if ( type.length > -1 )
						buff ~= strct.getHandleVar() ~"."~ tokenToGtkD(strct.fields[type.length].name, wrapper.aliasses) ~" = cast("~ stringToGtkD(strct.fields[type.length].type.cType, wrapper.aliasses) ~")value.length;";
				}
				buff ~= "}";
			}
			else
			{
				if ( type.size > 0 )
				{
					buff ~= "public @property void "~ tokenToGtkD(name, wrapper.aliasses, strct.aliases) ~"(char["~ type.size.to!string ~"] value)";
					buff ~= "{";
					buff ~= strct.getHandleVar() ~"."~ tokenToGtkD(name, wrapper.aliasses) ~" = value;";
					buff ~= "}";
				}
				else
				{
					buff ~= "public @property void "~ tokenToGtkD(name, wrapper.aliasses, strct.aliases) ~"(string value)";
					buff ~= "{";
					buff ~= strct.getHandleVar() ~"."~ tokenToGtkD(name, wrapper.aliasses) ~" = Str.toStringz(value);";
					buff ~= "}";
				}
			}
		}
		else if ( dType && dType.isDClass() && type.cType.endsWith("*") )
		{
			if ( type.isArray() )
			{
				buff ~= "public @property void "~ tokenToGtkD(name, wrapper.aliasses, strct.aliases) ~"("~ dTypeName ~"["~ ((type.size > 0)?type.size.to!string:"") ~"] value)";
				buff ~= "{";
				if ( type.size > 0 )
					buff ~= dType.cType ~"*["~ type.size.to!string ~"] arr;";
				else
					buff ~= dType.cType ~"*[] arr = new "~ dType.cType ~"*[value.length+1];";
				buff ~= "for ( int i = 0; i < value.length; i++ )";
				buff ~= "{";
				buff ~= "arr[i] = value[i]."~ dType.getHandleFunc() ~"();";
				buff ~= "}";
				buff ~= "arr[value.length] = null;";
				buff ~= "";
				buff ~= strct.getHandleVar() ~"."~ tokenToGtkD(name, wrapper.aliasses) ~" = arr.ptr;";

				if ( type.length > -1 )
					buff ~= strct.getHandleVar() ~"."~ tokenToGtkD(strct.fields[type.length].name, wrapper.aliasses) ~" = cast("~ stringToGtkD(strct.fields[type.length].type.cType, wrapper.aliasses) ~")value.length;";

				buff ~= "}";
			}
			else
			{
				buff ~= "public @property void "~ tokenToGtkD(name, wrapper.aliasses, strct.aliases) ~"("~ dTypeName ~" value)";
				buff ~= "{";
				buff ~= strct.getHandleVar() ~"."~ tokenToGtkD(name, wrapper.aliasses) ~" = value."~ dType.getHandleFunc() ~"();";
				buff ~= "}";
			}
		}
		else if ( type.name.among("bool", "gboolean") || ( type.isArray && type.elementType.name.among("bool", "gboolean") ) )
		{
			if ( type.isArray() )
			{
				buff ~= "public @property void "~ tokenToGtkD(name, wrapper.aliasses, strct.aliases) ~"(bool["~ ((type.size > 0)?type.size.to!string:"") ~"] value)";
				buff ~= "{";
				if ( type.size > 0 )
				{
					buff ~= strct.getHandleVar() ~"."~ tokenToGtkD(name, wrapper.aliasses) ~" = value;";	
				}
				else
				{
					buff ~= strct.getHandleVar() ~"."~ tokenToGtkD(name, wrapper.aliasses) ~" = value.ptr;";
					if ( type.length > -1 )
						buff ~= strct.getHandleVar() ~"."~ tokenToGtkD(strct.fields[type.length].name, wrapper.aliasses) ~" = cast("~ stringToGtkD(strct.fields[type.length].type.cType, wrapper.aliasses) ~")value.length;";
				}
				buff ~= "}";
			}
			else
			{
				buff ~= "public @property void "~ tokenToGtkD(name, wrapper.aliasses, strct.aliases) ~"(bool value)";
				buff ~= "{";
				buff ~= strct.getHandleVar() ~"."~ tokenToGtkD(name, wrapper.aliasses) ~" = value;";				
				buff ~= "}";
			}
		}
		else
		{
			if ( type.isArray() )
			{
				if ( type.size > 0 && dType && dType.isDClass() )
				{
					buff ~= "public @property void "~ tokenToGtkD(name, wrapper.aliasses, strct.aliases) ~"("~ dTypeName ~"["~ type.size.to!string() ~"] value)";
					buff ~= "{";
					buff ~= "for ( int i = 0; i < value.length; i++ )";
					buff ~= "{";
					buff ~= strct.getHandleVar() ~"."~ tokenToGtkD(name, wrapper.aliasses) ~"[i] = *(value[i]."~ dType.getHandleFunc() ~"());";
					buff ~= "}";
					buff ~= "}";
				}
				else if ( type.size > 0 )
				{
					buff ~= "public @property void "~ tokenToGtkD(name, wrapper.aliasses, strct.aliases) ~"("~ stringToGtkD(type.cType, wrapper.aliasses, strct.aliases) ~"["~ ((type.size > 0)?type.size.to!string:"") ~"] value)";
					buff ~= "{";
					buff ~= strct.getHandleVar() ~"."~ tokenToGtkD(name, wrapper.aliasses) ~" = value;";	
					buff ~= "}";
				}
				else
				{
					buff ~= "public @property void "~ tokenToGtkD(name, wrapper.aliasses, strct.aliases) ~"("~ stringToGtkD(type.cType[0..$-1], wrapper.aliasses, strct.aliases) ~"["~ ((type.size > 0)?type.size.to!string:"") ~"] value)";
					buff ~= "{";
					buff ~= strct.getHandleVar() ~"."~ tokenToGtkD(name, wrapper.aliasses) ~" = value.ptr;";
	
					if ( type.length > -1 )
						buff ~= strct.getHandleVar() ~"."~ tokenToGtkD(strct.fields[type.length].name, wrapper.aliasses) ~" = cast("~ stringToGtkD(strct.fields[type.length].type.cType, wrapper.aliasses) ~")value.length;";

					buff ~= "}";
				}
			}
			else
			{
				buff ~= "public @property void "~ tokenToGtkD(name, wrapper.aliasses, strct.aliases) ~"("~ stringToGtkD(type.cType, wrapper.aliasses, strct.aliases) ~" value)";
				buff ~= "{";
				buff ~= strct.getHandleVar() ~"."~ tokenToGtkD(name, wrapper.aliasses) ~" = value;";
				buff ~= "}";
			}
		}
	}

	private void writeDocs(ref string[] buff)
	{
		if ( doc !is null && wrapper.includeComments )
		{
			buff ~= "/**";
			foreach ( line; doc.splitLines() )
				buff ~= " * "~ line.strip();

			buff ~= " */";
		}
		else if ( wrapper.includeComments )
		{
			buff ~= "/** */";
		}
	}

	private string getLengthID(GirStruct strct)
	{
		if ( type.length > -1 )
			return strct.getHandleVar() ~"."~ tokenToGtkD(strct.fields[type.length].name, wrapper.aliasses);
		else if ( type.size > 0 )
			return to!string(type.size);

		return null;
	}
}
